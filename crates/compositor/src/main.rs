// SPDX-FileCopyrightText: 2025 Oxyde Contributors
// SPDX-License-Identifier: MPL-2.0

use anyhow::Result;
use calloop::{EventLoop, LoopSignal};
use tracing::{error, info};
use tracing_subscriber::EnvFilter;

use smithay::reexports::wayland_server::{
    protocol::{wl_output::WlOutput, wl_seat::WlSeat, wl_shm},
    Display, DisplayHandle, ListeningSocket,
};

use smithay::utils::{Logical, Serial, Size};

use smithay::input::{Seat, SeatHandler, SeatState};
use smithay::output::{Mode, Output, PhysicalProperties, Subpixel, Transform};

use smithay::wayland::{
    compositor::{CompositorHandler, CompositorState},
    shm::{ShmHandler, ShmState},
    shell::xdg::{
        PopupSurface, PositionerState, ResizeEdge, ToplevelSurface, XdgShellHandler, XdgShellState,
    },
    shell::wlr_layer::{Layer, LayerShellHandler, LayerSurface, LayerShellState},
};

/* ===================== Compositor state ===================== */

struct OxydeState {
    dh: DisplayHandle,
    compositor: CompositorState,
    shm: ShmState,
    xdg_shell: XdgShellState,
    layer_shell: LayerShellState,
    seat_state: SeatState<OxydeState>,
    _seat: Seat<OxydeState>,
    output: Output,
    _listening_socket: ListeningSocket,
    _signal: LoopSignal,
}

impl OxydeState {
    fn new(
        display: &mut Display<Self>,
        signal: LoopSignal,
        _size: Logical<Size<i32, smithay::utils::Logical>>,
        socket_name: &str,
    ) -> Result<Self> {
        let dh = display.handle();

        // Wayland socket (e.g., "wayland-1")
        let listening_socket = ListeningSocket::bind(socket_name)?;

        // Core globals
        let shm = ShmState::new(&dh, vec![wl_shm::Format::Argb8888, wl_shm::Format::Xrgb8888]);
        let compositor = CompositorState::new::<Self>(&dh);
        let xdg_shell = XdgShellState::new::<Self>(&dh);
        let layer_shell = LayerShellState::new::<Self>(&dh);

        // Seat (input placeholder for now)
        let mut seat_state = SeatState::new();
        let seat = seat_state.new_wl_seat(&dh, "seat-oxyde");
        seat.add_pointer();
        seat.add_keyboard(Default::default(), 200, 25).ok();

        // One logical output so layer-shell clients (your bar) have a target
        let output = Output::new(
            "oxyde-virtual".to_string(),
            PhysicalProperties {
                size: (340, 220).into(), // ~13.3" at 1280x800; not critical
                subpixel: Subpixel::Unknown,
                make: "Oxyde".to_string(),
                model: "Virtual".to_string(),
                transform: Transform::_0,
            },
        );
        let mode = Mode {
            size: (1280, 800).into(),
            refresh: 60_000, // 60 Hz (mHz)
        };
        output.change_current_state(Some(mode.clone()), None, None, None);
        output.set_preferred(mode);

        Ok(Self {
            dh,
            compositor,
            shm,
            xdg_shell,
            layer_shell,
            seat_state,
            _seat: seat,
            output,
            _listening_socket: listening_socket,
            _signal: signal,
        })
    }
}

/* ===================== Required trait impls ===================== */

/* ---- Compositor ---- */
impl CompositorHandler for OxydeState {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor
    }
}
smithay::delegate_compositor!(OxydeState);

/* ---- SHM ---- */
impl ShmHandler for OxydeState {
    fn shm_state(&mut self) -> &mut ShmState {
        &mut self.shm
    }
}
smithay::delegate_shm!(OxydeState);

/* ---- Seat ---- */
impl SeatHandler for OxydeState {
    fn seat_state(&mut self) -> &mut SeatState<OxydeState> {
        &mut self.seat_state
    }
}

/* ---- XDG shell ---- */
impl XdgShellHandler for OxydeState {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell
    }

    fn new_toplevel(&mut self, _toplevel: ToplevelSurface) {}

    fn new_popup(&mut self, _popup: PopupSurface, _pos: PositionerState) {}

    fn grab(&mut self, _popup: PopupSurface, _wl_seat: WlSeat, _serial: Serial) {}

    fn reposition_request(&mut self, _popup: PopupSurface, _pos: PositionerState, _token: u32) {}

    fn move_request(&mut self, _toplevel: ToplevelSurface, _seat: WlSeat, _serial: Serial) {}

    fn resize_request(
        &mut self,
        _toplevel: ToplevelSurface,
        _seat: WlSeat,
        _serial: Serial,
        _edges: ResizeEdge,
    ) {
    }
}
smithay::delegate_xdg_shell!(OxydeState);

/* ---- wlr-layer-shell ---- */
impl LayerShellHandler for OxydeState {
    fn shell_state(&mut self) -> &mut LayerShellState {
        &mut self.layer_shell
    }

    fn new_layer_surface(
        &mut self,
        surface: LayerSurface,
        _output: Option<WlOutput>,
        _layer: Layer,
        _namespace: String,
    ) {
        // Minimal accept/map so your bar can anchor itself
        surface.with_pending_state(|_s| {});
        surface.commit();
    }
}
smithay::delegate_layer_shell!(OxydeState);

/* ===================== Main ===================== */

fn main() -> Result<()> {
    // Logging
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .init();

    info!("Oxyde compositor starting…");

    // Your module hooks (safe to keep)
    oxyde_panel::init();
    oxyde_theming::init();
    oxyde_oxynotify::init();
    oxyde_oxymenu::init();
    oxyde_oxykeys::init();
    oxyde_oxyconfig::init();
    oxyde_launcher::init();
    oxyde_expose::init();
    oxyde_dock::init();

    // Wayland display + event loop
    let mut event_loop: EventLoop<'static, OxydeState> = EventLoop::try_new()?;
    let signal = event_loop.get_signal();
    let mut display: Display<OxydeState> = Display::new()?;

    // Create compositor state (wayland-1)
    let mut state = OxydeState::new(
        &mut display,
        signal.clone(),
        Logical::<Size<i32, _>>::from((1280, 800)),
        "wayland-1",
    )?;

    // Periodically flush Wayland clients
    let _wl_source = display.insert_source(&mut event_loop, |_, _, state: &mut OxydeState| {
        if let Err(e) = state.dh.flush_clients() {
            error!("flush_clients error: {e:?}");
        }
    })?;

    info!("Wayland up on WAYLAND_DISPLAY=wayland-1");
    info!("Launch your bar with: WAYLAND_DISPLAY=wayland-1 ./taskbar/bar_y2k");

    // Run
    event_loop.run(None, &mut state, |_state| {})?;
    Ok(())
}