//! Gate 1 mechanics. Selecting or qualifying a backend is the Host's explicit decision.
pub mod geometry;
#[cfg(target_os = "macos")]
mod native;
pub mod park;
pub mod patch;
pub mod sliver;
#[cfg(target_os = "macos")]
mod tap;
#[cfg(target_os = "macos")]
mod worker;
#[cfg(target_os = "macos")]
pub use worker::Corner;

#[cfg(not(target_os = "macos"))]
#[derive(Default)]
pub struct Corner;
#[cfg(not(target_os = "macos"))]
impl crate::contract::WindowEngine for Corner {
    fn execute(
        &mut self,
        _: &crate::contract::Request,
        _: &crate::contract::Control,
    ) -> crate::contract::Outcome {
        crate::contract::Outcome::new(crate::contract::UNSUPPORTED)
    }
}
