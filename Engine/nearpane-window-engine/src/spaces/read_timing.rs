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

// One summary per issued move, including early returns. Full views remain
// independently timed above; no polling iteration emits another stage record.
pub(super) struct MoveConfirmationTiming {
    enabled: bool,
    window: Window,
    target: u64,
    began: Instant,
    acknowledgement_budget: Duration,
    confirmation_budget: Duration,
    acknowledged: Option<Duration>,
    full_view_attempts: u32,
    positive_full_views: u32,
    completed: bool,
}
impl MoveConfirmationTiming {
    pub(super) fn new(window: Window, target: u64, began: Instant,
        acknowledgement_budget: Duration, confirmation_budget: Duration) -> Self {
        Self { enabled: std::env::var_os("NP_SPACES_LAUNCH_TRACE").is_some(),
            window, target, began, acknowledgement_budget, confirmation_budget,
            acknowledged: None, full_view_attempts: 0, positive_full_views: 0, completed: false }
    }
    pub(super) fn acknowledged(&mut self, now: Instant) {
        self.acknowledged = Some(now.saturating_duration_since(self.began));
    }
    pub(super) fn begin_full_view(&mut self) {
        self.full_view_attempts = self.full_view_attempts.saturating_add(1);
    }
    pub(super) fn positive_full_view(&mut self) {
        self.positive_full_views = self.positive_full_views.saturating_add(1);
    }
    pub(super) fn completed(&mut self) { self.completed = true; }
}
impl Drop for MoveConfirmationTiming {
    fn drop(&mut self) {
        if !self.enabled { return; }
        let ack = self.acknowledged.map_or_else(|| "null".to_owned(),
            |elapsed| format!("{:.3}", elapsed.as_secs_f64() * 1000.0));
        let stage = if self.completed { "completed" }
            else if self.acknowledged.is_some() { "full-confirmation" }
            else { "membership-acknowledgement" };
        let _ = writeln!(std::io::stderr().lock(), "{{\"event\":\"spacesMoveConfirmation\",\"window\":{},\"pid\":{},\"target\":{},\"completed\":{},\"finalStage\":\"{}\",\"acknowledgementMS\":{},\"acknowledgementBudgetMS\":{:.3},\"confirmationBudgetMS\":{:.3},\"fullViewAttempts\":{},\"positiveFullViews\":{},\"durationMS\":{:.3}}}",
            self.window.number, self.window.pid, self.target, self.completed, stage, ack,
            self.acknowledgement_budget.as_secs_f64() * 1000.0,
            self.confirmation_budget.as_secs_f64() * 1000.0,
            self.full_view_attempts, self.positive_full_views,
            Instant::now().saturating_duration_since(self.began).as_secs_f64() * 1000.0);
    }
}
