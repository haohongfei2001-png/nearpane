// Build the actual crate contract and Corner sources without opening a GUI session or creating a tap.
#[path = "../../../../Engine/nearpane-window-engine/src/contract.rs"]
mod contract;
#[path = "../../../../Engine/nearpane-window-engine/src/corner/mod.rs"]
mod corner;

#[test]
fn default_construction_never_starts_a_tap_or_opens_a_window(){
    let _idle=corner::Corner::default();
}

#[test]
fn a_replaced_or_expired_compositor_packet_cannot_revoke_the_current_workset() {
    unsafe extern "C" { fn np_test_surface_interruption(); }
    unsafe { np_test_surface_interruption() }
}

#[test]
fn the_single_transparent_fixture_cannot_swallow_a_real_gesture() {
    use corner::geometry::{Point,Rect};
    use corner::sliver::{Button,DockBar,Listed,Press,PressGate,Shield};
    let box_=Rect::new(1399.,800.,160.,140.);
    let shield=Shield { on:true, zones:vec![Rect::new(1320.,760.,80.,140.)],
        parked:[21].into(), dock:DockBar::default() };
    let owned=Listed { id:21,pid:987,bounds:box_,alpha:0.,layer:0 };
    let other=Listed { id:22,pid:999,bounds:box_,alpha:1.,layer:0 };
    for rows in [vec![owned],vec![owned,other],vec![other,owned]] {
        for x in [1390.,1399.,1400.] {
            let at=Point::new(x,825.);
            assert!(shield.hits(&rows,at,-1).is_none());
            for button in [Button::Left,Button::Right,Button::Other] {
                let mut gate=PressGate::default();
                assert!(!gate.swallow(Press::Down(button),|| shield.hits(&rows,at,-1).is_some()));
                assert!(!gate.swallow(Press::Dragged(button),|| unreachable!()));
                assert!(!gate.swallow(Press::Up(button),|| unreachable!()));
            }
        }
    }
}
