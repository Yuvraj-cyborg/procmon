use std::collections::VecDeque;
use std::sync::Arc;
use std::time::Duration;

use gpui_kit::{AppContext as _, Context, Task};

use super::sampler::Sampler;
use super::snapshot::Snapshot;
use crate::units::Ratio;

const SAMPLE_INTERVAL: Duration = Duration::from_secs(1);
const HISTORY_LEN: usize = 120;

/// Shared model that every page observes. Owns the sampling loop.
pub struct Monitor {
    latest: Option<Arc<Snapshot>>,
    cpu_history: History<Ratio>,
    memory_history: History<Ratio>,
    _sampling: Task<()>,
}

impl Monitor {
    pub fn new(cx: &mut Context<Self>) -> Self {
        let sampling = cx.spawn(async move |this, cx| {
            let mut sampler = Sampler::new();
            loop {
                // The sampler moves to a worker thread and back so the UI thread
                // never blocks on hundreds of proc_pidinfo calls.
                let (returned, snapshot) = cx
                    .background_spawn(async move {
                        let snapshot = sampler.sample();
                        (sampler, snapshot)
                    })
                    .await;
                sampler = returned;
                let alive = this.update(cx, |monitor, cx| monitor.push(snapshot, cx));
                if alive.is_err() {
                    break;
                }
                cx.background_executor().timer(SAMPLE_INTERVAL).await;
            }
        });
        Self {
            latest: None,
            cpu_history: History::new(HISTORY_LEN),
            memory_history: History::new(HISTORY_LEN),
            _sampling: sampling,
        }
    }

    fn push(&mut self, snapshot: Snapshot, cx: &mut Context<Self>) {
        self.cpu_history.push(snapshot.cpu.total);
        self.memory_history
            .push(snapshot.memory.used.ratio_of(snapshot.memory.total));
        self.latest = Some(Arc::new(snapshot));
        cx.notify();
    }

    pub fn latest(&self) -> Option<Arc<Snapshot>> {
        self.latest.clone()
    }

    pub fn cpu_history(&self) -> &History<Ratio> {
        &self.cpu_history
    }

    pub fn memory_history(&self) -> &History<Ratio> {
        &self.memory_history
    }
}

/// Fixed-capacity ring of recent values, oldest first.
pub struct History<T> {
    values: VecDeque<T>,
    capacity: usize,
}

impl<T: Copy> History<T> {
    pub fn new(capacity: usize) -> Self {
        Self {
            values: VecDeque::with_capacity(capacity),
            capacity,
        }
    }

    pub fn push(&mut self, value: T) {
        if self.values.len() == self.capacity {
            self.values.pop_front();
        }
        self.values.push_back(value);
    }

    pub fn iter(&self) -> impl ExactSizeIterator<Item = T> + '_ {
        self.values.iter().copied()
    }

    pub fn capacity(&self) -> usize {
        self.capacity
    }
}

#[cfg(test)]
mod tests {
    use super::History;

    #[test]
    fn history_drops_oldest() {
        let mut h = History::new(3);
        for v in 1..=5 {
            h.push(v);
        }
        assert_eq!(h.iter().collect::<Vec<_>>(), vec![3, 4, 5]);
    }
}
