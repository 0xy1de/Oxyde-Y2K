// SPDX-License-Identifier: MPL-2.0

use std::{cell::RefCell, rc::Rc, sync::Arc, time::Duration};

use anyhow::Result;
use calloop::{EventLoop, LoopSignal};
use calloop::timer::{Timer, TimeoutAction};
use tracing::{error, info};
use tracing_subscriber::EnvFilter;

use smithay::{
    output::{Mode as OutputMode, Output, PhysicalProperties, Scale, Subpixel},
    reexports::wayland_server::{
        backend::{ClientData, ClientId, DisconnectReason},
        protocol::{
            wl_buffer::WlBuffer, wl_output::WlOutput, wl_seat::WlSeat, wl_shm, wl_surface::WlSurface,
        },
        Display, DisplayHandle,
    },
    utils::{Serial, Transform},
    input::{Seat, SeatHandler, SeatState},
    input::pointer::CursorImageStatus,
    wayland::{
        buffer::BufferHandler,
        compositor::{CompositorClientState, CompositorHandler, CompositorState},
        output::OutputHandler,
        shell::wlr_layer::{Layer, LayerSurface, WlrLayerShellHandler, WlrLayerShellState},
        shell::xdg::{PopupSurface, PositionerState, ToplevelSurface, XdgShellHandler, XdgShellState},
        shm::{ShmHandler, ShmState},
        socket::ListeningSocketSource,
    },
};

struct ClientState {
    compositor_state: CompositorClientState,
}
impl ClientData for ClientState {
    fn initialized(&self, _client: ClientId) {}
    fn disconnected(&self, _client: ClientId, _reason: DisconnectReason) {}
}

struct OxydeState {
    dh: DisplayHandle,
    compositor: CompositorState,
    shm: ShmState,
    xdg_shell: XdgShellState,
    layer_shell: WlrLayerShellState,
    seat_state: SeatState<Self>,
    _seat: Seat<Self>,
    output: Output,
    _signal: LoopSignal,
}

impl OxydeState {
    fn new(display: &mut Display<Self>, signal: LoopSignal) -> Result<Self> {
        let dh = display.handle();

        // Globals
        let shm = ShmState::new::<Self>(&dh, vec![wl_shm::Format::Argb8888, wl_shm::Format::Xrgb8888]);
        let compositor = CompositorState::new::<Self>(&dh);
        let xdg_shell = XdgShellState::new::<Self>(&dh);
        let layer_shell = WlrLayerShellState::new::<Self>(&dh);

        // Seat
        let mut seat_state = SeatState::new();
        let mut seat = seat_state.new_wl_seat(&dh, "seat-oxyde");
        seat.add_pointer();
        seat.add_keyboard(Default::default(), 200, 25).ok();

        // Output + wl_output global
        let output = Output::new(
            "oxyde-virtual".into(),
            PhysicalProperties {
                size: (200, 120).into(),
                subpixel: Subpixel::Unknown,
                make: "Oxyde".into(),
                model: "Virtual".into(),
            },
        );
        let _ = output.create_global::<Self>(&dh);

        let pref_mode = OutputMode {
            size: (1280, 800).into(),
            refresh: 60_000,
        };
        // ORDER in 0.7: (mode, transform, scale, location)
        output.change_current_state(
            Some(pref_mode.clone()),
            Some(Transform::Normal),
            Some(Scale::Integer(1)),
            None,
        );
        output.set_preferred(pref_mode);

        Ok(Self {
            dh,
            compositor,
            shm,
            xdg_shell,
            layer_shell,
            seat_state,
            _seat: seat,
            output,
            _signal: signal,
        })
    }
}

/* ---------- Required trait impls ---------- */

impl CompositorHandler for OxydeState {
    fn compositor_state(&mut self) -> &mut CompositorState {
        &mut self.compositor
    }

    fn client_compositor_state<'a>(
        &self,
        client: &'a smithay::reexports::wayland_server::Client,
    ) -> &'a CompositorClientState {
        &client.get_data::<ClientState>().unwrap().compositor_state
    }

    fn commit(&mut self, _surface: &WlSurface) {}
}
smithay::delegate_compositor!(OxydeState);

impl BufferHandler for OxydeState {
    fn buffer_destroyed(&mut self, _buffer: &WlBuffer) {}
}
impl ShmHandler for OxydeState {
    fn shm_state(&self) -> &ShmState {
        &self.shm
    }
}
smithay::delegate_shm!(OxydeState);

impl XdgShellHandler for OxydeState {
    fn xdg_shell_state(&mut self) -> &mut XdgShellState {
        &mut self.xdg_shell
    }

    fn new_toplevel(&mut self, _surface: ToplevelSurface) {}
    fn new_popup(&mut self, _surface: PopupSurface, _pos: PositionerState) {}
    fn grab(&mut self, _surface: PopupSurface, _seat: WlSeat, _serial: Serial) {}
    fn reposition_request(&mut self, _surface: PopupSurface, _pos: PositionerState, _token: u32) {}
}
smithay::delegate_xdg_shell!(OxydeState);

impl WlrLayerShellHandler for OxydeState {
    fn shell_state(&mut self) -> &mut WlrLayerShellState {
        &mut self.layer_shell
    }

    fn new_layer_surface(
        &mut self,
        _surface: LayerSurface,
        _output: Option<WlOutput>,
        _layer: Layer,
        _namespace: String,
    ) {
        // Minimal accept; no commit() call exists in 0.7 for server-side LayerSurface
    }
}
smithay::delegate_layer_shell!(OxydeState);

impl SeatHandler for OxydeState {
    type KeyboardFocus = WlSurface;
    type PointerFocus = WlSurface;
    type TouchFocus = WlSurface;

    fn seat_state(&mut self) -> &mut SeatState<Self> {
        &mut self.seat_state
    }
    fn focus_changed(&mut self, _seat: &Seat<Self>, _focus: Option<&WlSurface>) {}
    fn cursor_image(&mut self, _seat: &Seat<Self>, _image: CursorImageStatus) {}
}
smithay::delegate_seat!(OxydeState);

impl OutputHandler for OxydeState {}
smithay::delegate_output!(OxydeState);

/* ---------- Main ---------- */

fn main() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env().add_directive("info".parse().unwrap()))
        .init();

    info!("Oxyde compositor starting…");

    // your modules
    oxyde_panel::init();
    oxyde_theming::init();
    oxyde_oxynotify::init();
    oxyde_oxymenu::init();
    oxyde_oxykeys::init();
    oxyde_oxyconfig::init();
    oxyde_launcher::init();
    oxyde_expose::init();
    oxyde_dock::init();

    // Display first (so it outlives callbacks)
    let display_rc: Rc<RefCell<Display<OxydeState>>> = Rc::new(RefCell::new(Display::new()?));

    let mut event_loop: EventLoop<OxydeState> = EventLoop::try_new()?;
    let signal = event_loop.get_signal();

    // Build compositor state
    let mut state = {
        let mut d = display_rc.borrow_mut();
        OxydeState::new(&mut d, signal)?
    };

    // Accept new connections on wayland-1
    let wl_source = ListeningSocketSource::with_name("wayland-1")?;
    let mut dh = display_rc.borrow().handle();
    event_loop
        .handle()
        .insert_source(wl_source, move |stream, _, _state: &mut OxydeState| {
            if let Err(err) = dh.insert_client(
                stream,
                Arc::new(ClientState {
                    compositor_state: CompositorClientState::default(),
                }),
            ) {
                error!("Failed to insert Wayland client: {err:?}");
            }
        })?;

    // Drive Wayland with a tiny periodic timer (dispatch -> flush)
let display_for_cb = Rc::clone(&display_rc);

// Fire immediately once, then reschedule every 5ms via the return value:
let timer = calloop::timer::Timer::immediate();

let insert_res = event_loop
    .handle()
    .insert_source(timer, move |_, _, st: &mut OxydeState| {
        if let Err(err) = display_for_cb.borrow_mut().dispatch_clients(st) {
            error!("dispatch_clients error: {err:?}");
        }
        if let Err(err) = st.dh.flush_clients() {
            error!("flush_clients error: {err:?}");
        }
        calloop::timer::TimeoutAction::ToDuration(std::time::Duration::from_millis(5))
    });

// Don’t use `?` here; map to a plain anyhow error instead
if let Err(_e) = insert_res {
    return Err(anyhow::anyhow!("failed to insert timer source"));
}

    info!("Wayland up on WAYLAND_DISPLAY=wayland-1");
    info!("Launch your bar with:  WAYLAND_DISPLAY=wayland-1 ./taskbar/bar_y2k");

    event_loop.run(None, &mut state, |_| {})?;
    Ok(())
}