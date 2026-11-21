// Build the actual crate contract and Corner sources without opening a GUI session or creating a tap.
#[path = "../../../../Engine/nearpane-window-engine/src/contract.rs"]
mod contract;
#[path = "../../../../Engine/nearpane-window-engine/src/corner/mod.rs"]
mod corner;

#[test]
fn default_construction_never_starts_a_tap_or_opens_a_window(){
    let _idle=corner::Corner::default();
}
