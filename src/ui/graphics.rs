//! Graphics: how busy the GPU is, which processes use it, and a benchmark
//! that measures what it can do.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use gpui_kit::assets::IconName as Lucide;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::spinner::Spinner;
use gpui_kit::component::table::{DataTable, TableState};
use gpui_kit::component::{ActiveTheme, Icon, Sizable, h_flex, v_flex};
use gpui_kit::{
    AnyElement, AppContext as _, Context, Entity, IntoElement, ParentElement, Render, SharedString,
    Styled, Subscription, Task, Window, div, prelude::FluentBuilder as _, px,
};

use crate::app::Page;
use crate::gpu::{BenchError, BenchRecord, BenchTest, Benchmark, GpuStats};
use crate::settings::Settings;
use crate::system::Monitor;
use crate::theme::Tint;
use crate::ui::process_detail::ProcessDetail;
use crate::ui::process_table::{ProcessColumn, ProcessTable};
use crate::ui::widgets::{Card, Meter, PageHeader, Sparkline, Stat, page_body, page_scroll};
use crate::units::Ratio;

/// How long "Run for a minute" keeps the GPU busy.
const SUSTAIN: Duration = Duration::from_secs(60);
const HISTORY_KEPT: usize = 20;

pub struct GraphicsPage {
    monitor: Entity<Monitor>,
    table: Entity<TableState<ProcessTable>>,
    bench: BenchState,
    _observer: Subscription,
}

enum BenchState {
    Idle,
    Running {
        phase: SharedString,
        values: Vec<(BenchTest, f64)>,
        cancel: Arc<AtomicBool>,
        _task: Task<()>,
    },
    Sustaining {
        samples: Arc<Mutex<Vec<f64>>>,
        cancel: Arc<AtomicBool>,
        _task: Task<()>,
        _ticker: Task<()>,
    },
    /// The last run, kept on screen until the next one.
    Done {
        values: Vec<(BenchTest, f64)>,
        samples: Vec<f64>,
    },
    Failed(SharedString),
}

impl GraphicsPage {
    pub fn new(monitor: Entity<Monitor>, window: &mut Window, cx: &mut Context<Self>) -> Self {
        let columns = vec![
            ProcessColumn::Name,
            ProcessColumn::Gpu,
            ProcessColumn::GpuMemory,
            ProcessColumn::Cpu,
            ProcessColumn::Memory,
            ProcessColumn::Pid,
        ];
        let table = cx.new(|cx| {
            TableState::new(
                ProcessTable::new(columns, ProcessColumn::Gpu)
                    .only(|p| p.gpu.is_some())
                    .on_inspect({
                        let monitor = monitor.clone();
                        move |pid, name, window, cx| {
                            ProcessDetail::open(pid, name, monitor.clone(), window, cx)
                        }
                    }),
                window,
                cx,
            )
            .col_movable(false)
            .row_selectable(false)
        });
        let observer = cx.observe(&monitor, |this, monitor, cx| {
            if let Some(snapshot) = monitor.read(cx).latest() {
                this.table.update(cx, |table, cx| {
                    table.delegate_mut().update(&snapshot);
                    cx.notify();
                });
            }
            cx.notify();
        });
        Self {
            monitor,
            table,
            bench: BenchState::Idle,
            _observer: observer,
        }
    }

    fn busy(&self) -> bool {
        matches!(
            self.bench,
            BenchState::Running { .. } | BenchState::Sustaining { .. }
        )
    }

    fn stop(&mut self, cx: &mut Context<Self>) {
        if let BenchState::Running { cancel, .. } | BenchState::Sustaining { cancel, .. } =
            &self.bench
        {
            cancel.store(true, Ordering::Relaxed);
        }
        cx.notify();
    }

    /// Runs each test in turn on a worker thread, showing results as they land.
    fn run(&mut self, cx: &mut Context<Self>) {
        let cancel = Arc::new(AtomicBool::new(false));
        let task = cx.spawn({
            let cancel = cancel.clone();
            async move |this, cx| {
                let opened = cx.background_spawn(async { Benchmark::open() }).await;
                let mut bench = match opened {
                    Ok(bench) => bench,
                    Err(err) => {
                        this.update(cx, |this, cx| this.fail(&err, cx)).ok();
                        return;
                    }
                };
                let mut values = Vec::new();
                for test in BenchTest::ALL {
                    if !bench.supports(test) {
                        continue;
                    }
                    let phase: SharedString =
                        format!("Measuring {}…", test.label().to_lowercase()).into();
                    let shown = values.clone();
                    if this
                        .update(cx, |this, cx| {
                            if let BenchState::Running {
                                phase: p,
                                values: v,
                                ..
                            } = &mut this.bench
                            {
                                *p = phase;
                                *v = shown;
                            }
                            cx.notify();
                        })
                        .is_err()
                    {
                        return;
                    }
                    let flag = cancel.clone();
                    let (returned, result) = cx
                        .background_spawn(async move {
                            let result = bench.measure(test, &flag);
                            (bench, result)
                        })
                        .await;
                    bench = returned;
                    match result {
                        Ok(value) => values.push((test, value)),
                        Err(BenchError::Cancelled) => break,
                        Err(err) => {
                            this.update(cx, |this, cx| this.fail(&err, cx)).ok();
                            return;
                        }
                    }
                }
                let gpu = bench.gpu_name();
                this.update(cx, |this, cx| this.finish(gpu, values, cx))
                    .ok();
            }
        });
        self.bench = BenchState::Running {
            phase: "Preparing the GPU…".into(),
            values: Vec::new(),
            cancel,
            _task: task,
        };
        cx.notify();
    }

    /// Keeps the GPU at full load for a minute, charting each second.
    fn sustain(&mut self, cx: &mut Context<Self>) {
        let cancel = Arc::new(AtomicBool::new(false));
        let samples = Arc::new(Mutex::new(Vec::new()));
        let task = cx.spawn({
            let (cancel, samples) = (cancel.clone(), samples.clone());
            async move |this, cx| {
                let result = cx
                    .background_spawn(async move {
                        let mut bench = Benchmark::open()?;
                        bench.sustain(SUSTAIN, &cancel, |value| {
                            if let Ok(mut samples) = samples.lock() {
                                samples.push(value);
                            }
                        })
                    })
                    .await;
                this.update(cx, |this, cx| {
                    let samples = match &this.bench {
                        BenchState::Sustaining { samples, .. } => {
                            samples.lock().map(|s| s.clone()).unwrap_or_default()
                        }
                        _ => Vec::new(),
                    };
                    match result {
                        Ok(()) | Err(BenchError::Cancelled) => {
                            this.bench = BenchState::Done {
                                values: Vec::new(),
                                samples,
                            }
                        }
                        Err(err) => this.fail(&err, cx),
                    }
                    cx.notify();
                })
                .ok();
            }
        });
        let ticker = cx.spawn(async move |this, cx| {
            loop {
                cx.background_executor()
                    .timer(Duration::from_millis(500))
                    .await;
                if this.update(cx, |_, cx| cx.notify()).is_err() {
                    break;
                }
            }
        });
        self.bench = BenchState::Sustaining {
            samples,
            cancel,
            _task: task,
            _ticker: ticker,
        };
        cx.notify();
    }

    fn fail(&mut self, err: &BenchError, cx: &mut Context<Self>) {
        self.bench = BenchState::Failed(err.to_string().into());
        cx.notify();
    }

    fn finish(&mut self, gpu: String, values: Vec<(BenchTest, f64)>, cx: &mut Context<Self>) {
        if !values.is_empty() {
            let when = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_secs() as i64);
            let record = BenchRecord {
                when,
                gpu,
                values: values.clone(),
            };
            Settings::update(cx, |settings| {
                settings.benchmarks.insert(0, record);
                settings.benchmarks.truncate(HISTORY_KEPT);
            });
        }
        self.bench = BenchState::Done {
            values,
            samples: Vec::new(),
        };
        cx.notify();
    }

    fn render_gpu(&self, gpu: Option<&GpuStats>, cx: &Context<Self>) -> AnyElement {
        let theme = cx.theme();
        let muted = theme.muted_foreground;
        let Some(gpu) = gpu else {
            return Card::new()
                .title("GPU")
                .child(
                    div()
                        .text_sm()
                        .text_color(muted)
                        .child("This system doesn't report GPU readings Procmon can read."),
                )
                .into_any_element();
        };
        let history = self.monitor.read(cx).gpu_history();
        let memory = match (gpu.memory_used, gpu.memory_total) {
            (Some(used), Some(total)) => Some((used, Some(total))),
            (Some(used), None) => Some((used, None)),
            _ => None,
        };
        Card::new()
            .title(gpu.name.clone().unwrap_or_else(|| "GPU".into()))
            .child(
                h_flex()
                    .flex_wrap()
                    .gap_6()
                    .items_end()
                    .child(match gpu.utilization {
                        Some(load) => Stat::new("Busy", load.percent().to_string()),
                        None => Stat::new("Busy", "—").hint("not reported by the driver"),
                    })
                    .when(gpu.utilization.is_some(), |row| {
                        row.child(
                            div()
                                .flex_1()
                                .min_w(px(200.))
                                .h(px(56.))
                                .child(Sparkline::new(
                                    history.iter(),
                                    history.capacity(),
                                    theme.primary,
                                )),
                        )
                    })
                    .children(memory.map(|(used, total)| {
                        let value = match total {
                            Some(total) => format!("{} of {}", used.binary(), total.binary()),
                            None => used.binary().to_string(),
                        };
                        v_flex()
                            .gap_1()
                            .min_w(px(180.))
                            .child(Stat::new("Video memory", value))
                            .children(total.map(|total| {
                                Meter::single(used.ratio_of(total), Tint::Purple.strong())
                                    .height(px(6.))
                            }))
                    })),
            )
            .into_any_element()
    }

    fn render_benchmark(&self, cx: &mut Context<Self>) -> AnyElement {
        let muted = cx.theme().muted_foreground;
        let history = Settings::get(cx).benchmarks.clone();
        let busy = self.busy();
        let actions = h_flex()
            .gap_2()
            .when(busy, |row| {
                row.child(
                    Button::new("stop-benchmark")
                        .label("Stop")
                        .small()
                        .outline()
                        .on_click(cx.listener(|this, _, _, cx| this.stop(cx))),
                )
            })
            .when(!busy, |row| {
                row.child(
                    Button::new("sustain")
                        .label("Run for a minute")
                        .small()
                        .outline()
                        .on_click(cx.listener(|this, _, _, cx| this.sustain(cx))),
                )
                .child(
                    Button::new("benchmark")
                        .label("Run benchmark")
                        .icon(Icon::new(Lucide::Gauge))
                        .small()
                        .primary()
                        .on_click(cx.listener(|this, _, _, cx| this.run(cx))),
                )
            });

        let (values, phase, samples): (Vec<(BenchTest, f64)>, Option<SharedString>, Vec<f64>) =
            match &self.bench {
                BenchState::Running { phase, values, .. } => {
                    (values.clone(), Some(phase.clone()), Vec::new())
                }
                BenchState::Sustaining { samples, .. } => (
                    Vec::new(),
                    Some("Keeping the GPU at full load…".into()),
                    samples.lock().map(|s| s.clone()).unwrap_or_default(),
                ),
                BenchState::Done { values, samples } => (values.clone(), None, samples.clone()),
                BenchState::Idle | BenchState::Failed(_) => (
                    history
                        .first()
                        .map(|r| r.values.clone())
                        .unwrap_or_default(),
                    None,
                    Vec::new(),
                ),
            };
        let best = |test: BenchTest| {
            history
                .iter()
                .filter_map(|r| r.value(test))
                .fold(None, |m: Option<f64>, v| Some(m.map_or(v, |m| m.max(v))))
        };

        Card::new()
            .title("Benchmark")
            .trailing(actions)
            .child(
                div()
                    .text_xs()
                    .text_color(muted)
                    .child("Measures how much math the GPU can do per second and how fast it moves memory. Takes a few seconds; other apps may stutter while it runs."),
            )
            .child(
                h_flex().flex_wrap().gap_x_10().gap_y_3().children(BenchTest::ALL.map(|test| {
                    let value = values.iter().find(|(t, _)| *t == test).map(|(_, v)| *v);
                    let stat = Stat::new(test.label(), value.map_or_else(|| "—".to_string(), |v| test.format(v)));
                    match (value, best(test)) {
                        (Some(value), Some(best)) if best > 0.0 && history.len() > 1 => {
                            stat.hint(format!("{:.0}% of your best", value / best * 100.0))
                        }
                        _ => stat,
                    }
                })),
            )
            .children(phase.map(|phase| {
                h_flex()
                    .gap_2()
                    .text_sm()
                    .text_color(muted)
                    .child(Spinner::new().small())
                    .child(phase)
            }))
            .when(!samples.is_empty(), |card| {
                let peak = samples.iter().copied().fold(0.0f64, f64::max);
                let last = samples.last().copied().unwrap_or(0.0);
                let ratios: Vec<Ratio> = samples.iter().map(|s| Ratio::new(if peak > 0.0 { s / peak } else { 0.0 })).collect();
                card.child(
                    v_flex()
                        .gap_1()
                        .child(
                            div()
                                .h(px(64.))
                                .child(Sparkline::new(ratios, SUSTAIN.as_secs() as usize, Tint::Orange.strong())),
                        )
                        .child(div().text_xs().text_color(muted).child(format!(
                            "Peak {} · now {} · holding {:.0}% of its peak",
                            BenchTest::Fp32.format(peak),
                            BenchTest::Fp32.format(last),
                            if peak > 0.0 { last / peak * 100.0 } else { 0.0 }
                        ))),
                )
            })
            .when_some(
                match &self.bench {
                    BenchState::Failed(message) => Some(message.clone()),
                    _ => None,
                },
                |card, message| card.child(div().text_sm().text_color(Tint::Red.strong()).child(message)),
            )
            .when(history.len() > 1, |card| {
                card.child(
                    v_flex()
                        .gap_1()
                        .child(div().text_xs().text_color(muted).child("Earlier runs"))
                        .children(history.iter().take(5).map(|record| {
                            let date = crate::recovery::Timestamp::from_unix(record.when);
                            let summary = record
                                .values
                                .iter()
                                .map(|(test, value)| test.format(*value))
                                .collect::<Vec<_>>()
                                .join(" · ");
                            h_flex()
                                .gap_3()
                                .text_xs()
                                .child(div().w(px(120.)).text_color(muted).child(date.to_string()))
                                .child(div().flex_1().truncate().child(summary))
                        })),
                )
            })
            .into_any_element()
    }
}

impl Render for GraphicsPage {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        let header = PageHeader::new(Page::Graphics.title(), Page::Graphics.subtitle());
        let snapshot = self.monitor.read(cx).latest();
        let gpu = snapshot.as_ref().and_then(|s| s.gpu.clone());
        let using = snapshot.as_ref().map_or(0, |s| {
            s.processes.iter().filter(|p| p.gpu.is_some()).count()
        });
        page_scroll("graphics-page")
            .child(
                page_body()
                    .child(header)
                    .child(self.render_gpu(gpu.as_ref(), cx))
                    .child(self.render_benchmark(cx))
                    .child(
                        div().flex_1().min_h(px(320.)).flex().child(
                            Card::new()
                                .grow()
                                .title("Processes using the GPU")
                                .trailing(
                                    div()
                                        .text_xs()
                                        .text_color(cx.theme().muted_foreground)
                                        .child(format!("{using} right now")),
                                )
                                .child(
                                    div()
                                        .flex_1()
                                        .min_h_0()
                                        .child(DataTable::new(&self.table).bordered(false).small()),
                                ),
                        ),
                    ),
            )
            .into_any_element()
    }
}
