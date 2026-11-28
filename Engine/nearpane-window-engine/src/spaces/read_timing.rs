//! Bounded, opt-in timings of the existing read path. No extra native queries,
//! deadlines or retries; an early return records the exact unfinished stage.
use super::Window;
use std::fmt::Write;
use std::io::Write as _;
use std::time::{Duration, Instant};

pub(super) struct ReadTiming {
    operation: &'static str,
    window: Window,
    state: Option<Timing>,
}
struct Timing {
    began: Instant,
    last: Instant,
    stage: &'static str,
    stages: [(&'static str, Duration); 10],
    count: usize,
    completed: bool,
}
impl ReadTiming {
    pub(super) fn new(operation: &'static str, window: Window, stage: &'static str) -> Self {
        let state = std::env::var_os("NP_SPACES_LAUNCH_TRACE").map(|_| {
            let began = Instant::now();
            Timing { began, last: began, stage, stages: [("", Duration::ZERO); 10], count: 0, completed: false }
        });
        Self { operation, window, state }
    }
    pub(super) fn stage(&mut self, next: &'static str) {
        if let Some(t) = &mut self.state {
            let now = Instant::now();
            if t.count < t.stages.len() {
                t.stages[t.count] = (t.stage, now.saturating_duration_since(t.last));
                t.count += 1;
            }
            t.last = now;
            t.stage = next;
        }
    }
    pub(super) fn completed(&mut self) {
        if let Some(t) = &mut self.state { t.completed = true; }
    }
}
impl Drop for ReadTiming {
    fn drop(&mut self) {
        let Some(t) = self.state.as_ref() else { return };
        let final_stage = t.stage;
        self.stage(final_stage);
        let t = self.state.as_ref().unwrap();
        let mut stages = String::new();
        for (i, (name, elapsed)) in t.stages[..t.count].iter().enumerate() {
            let _ = write!(stages, "{}{{\"stage\":\"{}\",\"durationMS\":{:.3}}}",
                if i == 0 { "" } else { "," }, name, elapsed.as_secs_f64() * 1000.0);
        }
        // Diagnostics must not panic during this Drop (or another Drop while
        // unwinding), even if the trace consumer has closed its stderr pipe.
        let _ = writeln!(std::io::stderr().lock(), "{{\"event\":\"spacesNativeReadTiming\",\"operation\":\"{}\",\"window\":{},\"pid\":{},\"completed\":{},\"finalStage\":\"{}\",\"durationMS\":{:.3},\"stages\":[{}]}}",
            self.operation, self.window.number, self.window.pid, t.completed, final_stage,
            t.last.saturating_duration_since(t.began).as_secs_f64() * 1000.0, stages);
    }
}
