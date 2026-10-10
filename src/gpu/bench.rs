//! A short GPU benchmark in real units: how many trillion fused multiply-adds
//! per second the GPU sustains at 32 and 16 bits, and how fast it streams
//! memory. Each test is sized to take about 40 ms per run and repeated, so
//! the whole benchmark takes a few seconds.
//!
//! Linux runs WGSL compute shaders through wgpu (Vulkan or OpenGL), Windows
//! runs HLSL through Direct3D 11, both already part of the app's renderer.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BenchTest {
    Fp32,
    Fp16,
    Bandwidth,
}

impl BenchTest {
    pub const ALL: [BenchTest; 3] = [BenchTest::Fp32, BenchTest::Fp16, BenchTest::Bandwidth];

    pub fn label(self) -> &'static str {
        match self {
            BenchTest::Fp32 => "32-bit compute",
            BenchTest::Fp16 => "16-bit compute",
            BenchTest::Bandwidth => "Memory speed",
        }
    }

    pub fn format(self, value: f64) -> String {
        match self {
            // FLOPS count a fused multiply-add as two operations.
            BenchTest::Fp32 | BenchTest::Fp16 if value >= 1e12 => format!("{:.2} TFLOPS", value / 1e12),
            BenchTest::Fp32 | BenchTest::Fp16 => format!("{:.0} GFLOPS", value / 1e9),
            BenchTest::Bandwidth => format!("{:.0} GB/s", value / 1e9),
        }
    }
}

/// One finished benchmark, kept between launches.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BenchRecord {
    /// Seconds since 1970.
    pub when: i64,
    pub gpu: String,
    pub values: Vec<(BenchTest, f64)>,
}

impl BenchRecord {
    pub fn value(&self, test: BenchTest) -> Option<f64> {
        self.values.iter().find(|(t, _)| *t == test).map(|(_, v)| *v)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BenchError {
    NoGpu,
    Unsupported,
    Failed(String),
    Cancelled,
}

impl std::fmt::Display for BenchError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            BenchError::NoGpu => f.write_str("No GPU that runs compute shaders was found."),
            BenchError::Unsupported => f.write_str("Benchmarks aren't available on this system."),
            BenchError::Failed(detail) => write!(f, "The GPU stopped the benchmark: {detail}"),
            BenchError::Cancelled => f.write_str("Stopped."),
        }
    }
}

/// Threads per dispatch, each running the shader's loop.
const THREADS: u64 = 1 << 20;
/// Fused multiply-adds per loop: 16 vector FMAs on 4 lanes.
const FMAS_PER_LOOP: u64 = 64;
const TARGET: f64 = 0.04;

/// What a platform's GPU API must provide.
trait Backend: Send {
    fn name(&self) -> String;
    fn supports(&self, test: BenchTest) -> bool;
    /// GPU seconds for one dispatch running `loops` iterations per thread.
    fn compute(&mut self, test: BenchTest, loops: u32) -> Result<f64, BenchError>;
    /// Bytes read plus written, and seconds, for one round of copying.
    fn copy(&mut self) -> Result<(u64, f64), BenchError>;
}

pub struct Benchmark {
    backend: Box<dyn Backend>,
}

impl Benchmark {
    /// Sets up shaders on the system's main GPU. Slow (it compiles shaders):
    /// call off the UI thread.
    pub fn open() -> Result<Self, BenchError> {
        Ok(Self { backend: platform::open()? })
    }

    pub fn gpu_name(&self) -> String {
        self.backend.name()
    }

    pub fn supports(&self, test: BenchTest) -> bool {
        self.backend.supports(test)
    }

    /// FLOPS or bytes per second: the best of several timed runs, since
    /// anything else running only ever makes a run slower.
    pub fn measure(&mut self, test: BenchTest, cancel: &AtomicBool) -> Result<f64, BenchError> {
        if test == BenchTest::Bandwidth {
            let mut best = 0.0f64;
            for _ in 0..6 {
                if cancel.load(Ordering::Relaxed) {
                    return Err(BenchError::Cancelled);
                }
                let (bytes, seconds) = self.backend.copy()?;
                best = best.max(bytes as f64 / seconds.max(1e-9));
            }
            return Ok(best);
        }
        let loops = self.calibrate(test)?;
        let mut fastest = f64::MAX;
        for _ in 0..5 {
            if cancel.load(Ordering::Relaxed) {
                return Err(BenchError::Cancelled);
            }
            fastest = fastest.min(self.backend.compute(test, loops)?);
        }
        Ok((THREADS * u64::from(loops) * FMAS_PER_LOOP * 2) as f64 / fastest.max(1e-9))
    }

    /// Runs the 32-bit test back to back for `duration`, reporting each
    /// second's speed, to show whether the GPU slows down as it heats up.
    pub fn sustain(&mut self, duration: Duration, cancel: &AtomicBool, mut report: impl FnMut(f64)) -> Result<(), BenchError> {
        let loops = self.calibrate(BenchTest::Fp32)?;
        let start = Instant::now();
        while start.elapsed() < duration && !cancel.load(Ordering::Relaxed) {
            let window = Instant::now();
            let (mut flops, mut seconds) = (0.0, 0.0);
            while window.elapsed() < Duration::from_secs(1) && !cancel.load(Ordering::Relaxed) {
                seconds += self.backend.compute(BenchTest::Fp32, loops)?;
                flops += (THREADS * u64::from(loops) * FMAS_PER_LOOP * 2) as f64;
            }
            if seconds > 0.0 {
                report(flops / seconds);
            }
        }
        Ok(())
    }

    /// Loop count that makes one dispatch take about [`TARGET`] seconds.
    fn calibrate(&mut self, test: BenchTest) -> Result<u32, BenchError> {
        let mut loops = 64u32;
        for _ in 0..12 {
            let seconds = self.backend.compute(test, loops)?;
            if seconds >= TARGET / 2.0 {
                break;
            }
            let scale = if seconds > 0.0 { (TARGET / seconds).min(16.0) } else { 16.0 };
            loops = (f64::from(loops) * scale).min(1_000_000.0) as u32;
        }
        Ok(loops)
    }
}

#[cfg(target_os = "linux")]
mod platform {
    use std::time::Instant;

    use super::{Backend, BenchError, BenchTest, THREADS};

    /// `SCALAR` becomes `f32` or `f16`.
    const COMPUTE: &str = "
struct Params { loops: u32, pad0: u32, pad1: u32, pad2: u32 }
@group(0) @binding(0) var<storage, read_write> output: array<vec4<SCALAR>>;
@group(0) @binding(1) var<uniform> params: Params;
@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    var a0 = vec4<SCALAR>(SCALAR(id.x & 1023u) * SCALAR(1e-4));
    var a1 = a0 + vec4<SCALAR>(0.1); var a2 = a0 + vec4<SCALAR>(0.2); var a3 = a0 + vec4<SCALAR>(0.3);
    var a4 = a0 + vec4<SCALAR>(0.4); var a5 = a0 + vec4<SCALAR>(0.5); var a6 = a0 + vec4<SCALAR>(0.6); var a7 = a0 + vec4<SCALAR>(0.7);
    let m = vec4<SCALAR>(0.999); let k = vec4<SCALAR>(0.0001);
    for (var i = 0u; i < params.loops; i = i + 1u) {
        a0 = fma(a0, m, k); a1 = fma(a1, m, k); a2 = fma(a2, m, k); a3 = fma(a3, m, k);
        a4 = fma(a4, m, k); a5 = fma(a5, m, k); a6 = fma(a6, m, k); a7 = fma(a7, m, k);
        a0 = fma(a0, m, k); a1 = fma(a1, m, k); a2 = fma(a2, m, k); a3 = fma(a3, m, k);
        a4 = fma(a4, m, k); a5 = fma(a5, m, k); a6 = fma(a6, m, k); a7 = fma(a7, m, k);
    }
    output[id.x] = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7;
}
";

    const COPY: &str = "
@group(0) @binding(0) var<storage, read> source: array<vec4<f32>>;
@group(0) @binding(1) var<storage, read_write> target: array<vec4<f32>>;
@compute @workgroup_size(256)
fn main(@builtin(global_invocation_id) id: vec3<u32>, @builtin(num_workgroups) groups: vec3<u32>) {
    let stride = groups.x * 256u;
    let count = arrayLength(&target);
    for (var i = id.x; i < count; i = i + stride) {
        target[i] = source[i];
    }
}
";

    struct Kernel {
        pipeline: wgpu::ComputePipeline,
        bindings: wgpu::BindGroup,
    }

    struct Wgpu {
        name: String,
        device: wgpu::Device,
        queue: wgpu::Queue,
        params: wgpu::Buffer,
        fp32: Kernel,
        fp16: Option<Kernel>,
        copy: Kernel,
        copy_bytes: u64,
    }

    pub(super) fn open() -> Result<Box<dyn Backend>, BenchError> {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
            backends: wgpu::Backends::VULKAN | wgpu::Backends::GL,
            ..wgpu::InstanceDescriptor::new_without_display_handle()
        });
        let adapter = async_io::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            ..Default::default()
        }))
        .map_err(|_| BenchError::NoGpu)?;
        let half = adapter.features().contains(wgpu::Features::SHADER_F16);
        let limits = adapter.limits();
        let (device, queue) = async_io::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
            label: Some("benchmark"),
            required_features: if half { wgpu::Features::SHADER_F16 } else { wgpu::Features::empty() },
            required_limits: limits.clone(),
            ..Default::default()
        }))
        .map_err(|err| BenchError::Failed(err.to_string()))?;

        let params = device.create_buffer(&wgpu::BufferDescriptor {
            label: None,
            size: 16,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let storage = |size: u64| {
            device.create_buffer(&wgpu::BufferDescriptor {
                label: None,
                size,
                usage: wgpu::BufferUsages::STORAGE,
                mapped_at_creation: false,
            })
        };
        let kernel = |source: &str, buffers: [&wgpu::Buffer; 2]| {
            let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
                label: None,
                source: wgpu::ShaderSource::Wgsl(source.into()),
            });
            let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
                label: None,
                layout: None,
                module: &module,
                entry_point: Some("main"),
                compilation_options: Default::default(),
                cache: None,
            });
            let bindings = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: None,
                layout: &pipeline.get_bind_group_layout(0),
                entries: &[
                    wgpu::BindGroupEntry { binding: 0, resource: buffers[0].as_entire_binding() },
                    wgpu::BindGroupEntry { binding: 1, resource: buffers[1].as_entire_binding() },
                ],
            });
            Kernel { pipeline, bindings }
        };
        let fp32 = kernel(&COMPUTE.replace("SCALAR", "f32"), [&storage(THREADS * 16), &params]);
        let fp16 = half.then(|| {
            let source = format!("enable f16;\n{}", COMPUTE.replace("SCALAR", "f16"));
            kernel(&source, [&storage(THREADS * 8), &params])
        });
        // Large enough to spill out of any cache, within what the GPU allows.
        let copy_bytes = (256u64 << 20)
            .min(u64::from(limits.max_storage_buffer_binding_size))
            .min(limits.max_buffer_size)
            / 4096
            * 4096;
        let copy = kernel(COPY, [&storage(copy_bytes), &storage(copy_bytes)]);
        Ok(Box::new(Wgpu {
            name: adapter.get_info().name,
            device,
            queue,
            params,
            fp32,
            fp16,
            copy,
            copy_bytes,
        }))
    }

    impl Wgpu {
        /// Seconds from submitting `rounds` dispatches to their completion.
        fn run(&mut self, kernel: Which, groups: u32, rounds: u32) -> Result<f64, BenchError> {
            let kernel = match kernel {
                Which::Fp32 => &self.fp32,
                Which::Fp16 => self.fp16.as_ref().ok_or(BenchError::Unsupported)?,
                Which::Copy => &self.copy,
            };
            let mut encoder = self.device.create_command_encoder(&wgpu::CommandEncoderDescriptor::default());
            {
                let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor::default());
                pass.set_pipeline(&kernel.pipeline);
                pass.set_bind_group(0, &kernel.bindings, &[]);
                for _ in 0..rounds {
                    pass.dispatch_workgroups(groups, 1, 1);
                }
            }
            let started = Instant::now();
            self.queue.submit([encoder.finish()]);
            self.device
                .poll(wgpu::PollType::wait_indefinitely())
                .map_err(|err| BenchError::Failed(err.to_string()))?;
            Ok(started.elapsed().as_secs_f64())
        }
    }

    #[derive(Clone, Copy)]
    enum Which {
        Fp32,
        Fp16,
        Copy,
    }

    impl Backend for Wgpu {
        fn name(&self) -> String {
            self.name.clone()
        }

        fn supports(&self, test: BenchTest) -> bool {
            test != BenchTest::Fp16 || self.fp16.is_some()
        }

        fn compute(&mut self, test: BenchTest, loops: u32) -> Result<f64, BenchError> {
            let mut params = [0u8; 16];
            params[..4].copy_from_slice(&loops.to_le_bytes());
            self.queue.write_buffer(&self.params, 0, &params);
            let which = if test == BenchTest::Fp16 { Which::Fp16 } else { Which::Fp32 };
            self.run(which, (THREADS / 256) as u32, 1)
        }

        fn copy(&mut self) -> Result<(u64, f64), BenchError> {
            let rounds = 4;
            let seconds = self.run(Which::Copy, 4096, rounds)?;
            Ok((self.copy_bytes * 2 * u64::from(rounds), seconds))
        }
    }
}

#[cfg(windows)]
mod platform {
    use windows::Win32::Foundation::HMODULE;
    use windows::Win32::Graphics::Direct3D::Fxc::{D3DCOMPILE_OPTIMIZATION_LEVEL3, D3DCompile};
    use windows::Win32::Graphics::Direct3D::{D3D_DRIVER_TYPE_HARDWARE, D3D_FEATURE_LEVEL_11_0, ID3DBlob};
    use windows::Win32::Graphics::Direct3D11::*;
    use windows::Win32::Graphics::Dxgi::IDXGIDevice;
    use windows::core::{Interface as _, PCSTR};

    use super::{Backend, BenchError, BenchTest, THREADS};

    const SHADERS: &str = "
cbuffer Params : register(b0) { uint loops; uint stride; uint count; uint pad; };
RWStructuredBuffer<float4> output : register(u0);
StructuredBuffer<float4> source : register(t0);

#define BODY(T) \\
    T a0 = (T)((id.x & 1023) * 1e-4); T a1 = a0 + 0.1; T a2 = a0 + 0.2; T a3 = a0 + 0.3; \\
    T a4 = a0 + 0.4; T a5 = a0 + 0.5; T a6 = a0 + 0.6; T a7 = a0 + 0.7; \\
    const T m = 0.999; const T k = 0.0001; \\
    for (uint i = 0; i < loops; i++) { \\
        a0 = mad(a0, m, k); a1 = mad(a1, m, k); a2 = mad(a2, m, k); a3 = mad(a3, m, k); \\
        a4 = mad(a4, m, k); a5 = mad(a5, m, k); a6 = mad(a6, m, k); a7 = mad(a7, m, k); \\
        a0 = mad(a0, m, k); a1 = mad(a1, m, k); a2 = mad(a2, m, k); a3 = mad(a3, m, k); \\
        a4 = mad(a4, m, k); a5 = mad(a5, m, k); a6 = mad(a6, m, k); a7 = mad(a7, m, k); \\
    } \\
    output[id.x] = (float4)(a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7);

[numthreads(256, 1, 1)] void fp32(uint3 id : SV_DispatchThreadID) { BODY(float4) }
[numthreads(256, 1, 1)] void fp16(uint3 id : SV_DispatchThreadID) { BODY(min16float4) }
[numthreads(256, 1, 1)] void copy(uint3 id : SV_DispatchThreadID) {
    for (uint i = id.x; i < count; i += stride) { output[i] = source[i]; }
}
";

    const COPY_ELEMENTS: u32 = 16 << 20;
    const COPY_GROUPS: u32 = 4096;

    struct D3d {
        name: String,
        device: ID3D11Device,
        context: ID3D11DeviceContext,
        params: ID3D11Buffer,
        output: ID3D11UnorderedAccessView,
        shaders: [ID3D11ComputeShader; 3],
        copy: Option<(ID3D11ShaderResourceView, ID3D11UnorderedAccessView)>,
        queries: [ID3D11Query; 3],
    }

    // SAFETY: the device and its context are only used from the benchmark's thread.
    unsafe impl Send for D3d {}

    fn failed(err: windows::core::Error) -> BenchError {
        BenchError::Failed(err.message())
    }

    pub(super) fn open() -> Result<Box<dyn Backend>, BenchError> {
        // SAFETY: Direct3D calls with descriptors that live through each call.
        unsafe {
            let mut device = None;
            let mut context = None;
            D3D11CreateDevice(
                None,
                D3D_DRIVER_TYPE_HARDWARE,
                HMODULE::default(),
                D3D11_CREATE_DEVICE_FLAG(0),
                Some(&[D3D_FEATURE_LEVEL_11_0]),
                D3D11_SDK_VERSION,
                Some(&mut device),
                None,
                Some(&mut context),
            )
            .map_err(|_| BenchError::NoGpu)?;
            let (device, context): (ID3D11Device, ID3D11DeviceContext) =
                (device.ok_or(BenchError::NoGpu)?, context.ok_or(BenchError::NoGpu)?);
            let shader = |entry: &[u8]| -> Result<ID3D11ComputeShader, BenchError> {
                let mut code: Option<ID3DBlob> = None;
                D3DCompile(
                    SHADERS.as_ptr().cast(),
                    SHADERS.len(),
                    PCSTR::null(),
                    None,
                    None,
                    PCSTR(entry.as_ptr()),
                    PCSTR(c"cs_5_0".as_ptr().cast()),
                    D3DCOMPILE_OPTIMIZATION_LEVEL3,
                    0,
                    &mut code,
                    None,
                )
                .map_err(failed)?;
                let code = code.ok_or(BenchError::Unsupported)?;
                let bytes = std::slice::from_raw_parts(code.GetBufferPointer().cast::<u8>(), code.GetBufferSize());
                let mut shader = None;
                device.CreateComputeShader(bytes, None, Some(&mut shader)).map_err(failed)?;
                shader.ok_or(BenchError::Unsupported)
            };
            let shaders = [shader(b"fp32\0")?, shader(b"fp16\0")?, shader(b"copy\0")?];
            let mut params = None;
            device
                .CreateBuffer(
                    &D3D11_BUFFER_DESC {
                        ByteWidth: 16,
                        Usage: D3D11_USAGE_DEFAULT,
                        BindFlags: D3D11_BIND_CONSTANT_BUFFER.0 as u32,
                        ..Default::default()
                    },
                    None,
                    Some(&mut params),
                )
                .map_err(failed)?;
            let output = structured(&device, COPY_ELEMENTS.max(THREADS as u32))?;
            let output = unordered(&device, &output)?;
            let query = |kind| -> Result<ID3D11Query, BenchError> {
                let mut query = None;
                device
                    .CreateQuery(&D3D11_QUERY_DESC { Query: kind, MiscFlags: 0 }, Some(&mut query))
                    .map_err(failed)?;
                query.ok_or(BenchError::Unsupported)
            };
            let queries = [query(D3D11_QUERY_TIMESTAMP_DISJOINT)?, query(D3D11_QUERY_TIMESTAMP)?, query(D3D11_QUERY_TIMESTAMP)?];
            let name = device
                .cast::<IDXGIDevice>()
                .and_then(|dxgi| dxgi.GetAdapter())
                .and_then(|adapter| adapter.GetDesc())
                .map(|desc| {
                    let end = desc.Description.iter().position(|c| *c == 0).unwrap_or(desc.Description.len());
                    String::from_utf16_lossy(&desc.Description[..end])
                })
                .unwrap_or_else(|_| "GPU".into());
            Ok(Box::new(D3d {
                name,
                device,
                context,
                params: params.ok_or(BenchError::Unsupported)?,
                output,
                shaders,
                copy: None,
                queries,
            }))
        }
    }

    /// A buffer of `elements` float4s that shaders read and write.
    unsafe fn structured(device: &ID3D11Device, elements: u32) -> Result<ID3D11Buffer, BenchError> {
        let mut buffer = None;
        // SAFETY: the descriptor lives through the call.
        unsafe {
            device
                .CreateBuffer(
                    &D3D11_BUFFER_DESC {
                        ByteWidth: elements * 16,
                        Usage: D3D11_USAGE_DEFAULT,
                        BindFlags: (D3D11_BIND_UNORDERED_ACCESS.0 | D3D11_BIND_SHADER_RESOURCE.0) as u32,
                        MiscFlags: D3D11_RESOURCE_MISC_BUFFER_STRUCTURED.0 as u32,
                        StructureByteStride: 16,
                        ..Default::default()
                    },
                    None,
                    Some(&mut buffer),
                )
                .map_err(failed)?;
        }
        buffer.ok_or(BenchError::Unsupported)
    }

    unsafe fn unordered(device: &ID3D11Device, buffer: &ID3D11Buffer) -> Result<ID3D11UnorderedAccessView, BenchError> {
        let mut view = None;
        // SAFETY: a view of the whole buffer, with no explicit descriptor.
        unsafe { device.CreateUnorderedAccessView(buffer, None, Some(&mut view)) }.map_err(failed)?;
        view.ok_or(BenchError::Unsupported)
    }

    impl D3d {
        /// GPU seconds for `work`, from timestamp queries.
        fn timed(&self, work: impl FnOnce(&ID3D11DeviceContext)) -> Result<f64, BenchError> {
            let [disjoint, start, end] = &self.queries;
            // SAFETY: queries and context belong to the same device.
            unsafe {
                self.context.Begin(disjoint);
                self.context.End(start);
                work(&self.context);
                self.context.End(end);
                self.context.End(disjoint);
                // GetData writes nothing until the GPU has finished, so a
                // frequency of zero means "still running".
                let mut timing = D3D11_QUERY_DATA_TIMESTAMP_DISJOINT::default();
                let size = size_of::<D3D11_QUERY_DATA_TIMESTAMP_DISJOINT>() as u32;
                let waiting = std::time::Instant::now();
                while timing.Frequency == 0 {
                    self.context
                        .GetData(disjoint, Some(std::ptr::from_mut(&mut timing).cast()), size, 0)
                        .map_err(failed)?;
                    if waiting.elapsed() > std::time::Duration::from_secs(10) {
                        return Err(BenchError::Failed("the GPU did not finish".into()));
                    }
                    std::thread::yield_now();
                }
                let (mut first, mut last) = (0u64, 0u64);
                self.context.GetData(start, Some(std::ptr::from_mut(&mut first).cast()), 8, 0).map_err(failed)?;
                self.context.GetData(end, Some(std::ptr::from_mut(&mut last).cast()), 8, 0).map_err(failed)?;
                if timing.Disjoint.as_bool() || timing.Frequency == 0 {
                    return Err(BenchError::Failed("the GPU clock changed mid-run".into()));
                }
                Ok(last.saturating_sub(first) as f64 / timing.Frequency as f64)
            }
        }

        fn set_params(&self, loops: u32, stride: u32, count: u32) {
            let values = [loops, stride, count, 0];
            // SAFETY: 16 bytes into a 16-byte constant buffer.
            unsafe {
                self.context.UpdateSubresource(&self.params, 0, None, values.as_ptr().cast(), 0, 0);
                self.context.CSSetConstantBuffers(0, Some(&[Some(self.params.clone())]));
            }
        }
    }

    impl Backend for D3d {
        fn name(&self) -> String {
            self.name.clone()
        }

        fn supports(&self, _test: BenchTest) -> bool {
            true
        }

        fn compute(&mut self, test: BenchTest, loops: u32) -> Result<f64, BenchError> {
            self.set_params(loops, 0, 0);
            let shader = &self.shaders[if test == BenchTest::Fp16 { 1 } else { 0 }];
            // SAFETY: shader, view and context belong to the same device.
            unsafe {
                self.context.CSSetShader(shader, None);
                self.context.CSSetUnorderedAccessViews(0, 1, Some(&Some(self.output.clone())), None);
            }
            self.timed(|context| unsafe { context.Dispatch((THREADS / 256) as u32, 1, 1) })
        }

        fn copy(&mut self) -> Result<(u64, f64), BenchError> {
            if self.copy.is_none() {
                // SAFETY: buffers and views are created on this device.
                unsafe {
                    let source = structured(&self.device, COPY_ELEMENTS)?;
                    let target = structured(&self.device, COPY_ELEMENTS)?;
                    let mut view = None;
                    self.device.CreateShaderResourceView(&source, None, Some(&mut view)).map_err(failed)?;
                    self.copy = Some((view.ok_or(BenchError::Unsupported)?, unordered(&self.device, &target)?));
                }
            }
            let Some((source, target)) = self.copy.clone() else { return Err(BenchError::Unsupported) };
            self.set_params(0, COPY_GROUPS * 256, COPY_ELEMENTS);
            let rounds = 4;
            // SAFETY: as above.
            unsafe {
                self.context.CSSetShader(&self.shaders[2], None);
                self.context.CSSetShaderResources(0, Some(&[Some(source)]));
                self.context.CSSetUnorderedAccessViews(0, 1, Some(&Some(target)), None);
            }
            let seconds = self.timed(|context| {
                for _ in 0..rounds {
                    // SAFETY: the pipeline is fully bound above.
                    unsafe { context.Dispatch(COPY_GROUPS, 1, 1) };
                }
            })?;
            // SAFETY: unbinds the views so the buffers can be reused.
            unsafe { self.context.CSSetShaderResources(0, Some(&[None])) };
            Ok((u64::from(COPY_ELEMENTS) * 16 * 2 * rounds, seconds))
        }
    }
}

#[cfg(not(any(target_os = "linux", windows)))]
mod platform {
    use super::{Backend, BenchError};

    /// The shipped macOS app benchmarks with Metal.
    pub(super) fn open() -> Result<Box<dyn Backend>, BenchError> {
        Err(BenchError::Unsupported)
    }
}
