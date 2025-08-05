module ss

import term.ui as tui
import dbus

pub struct App {
mut: 
	user string
	initial bool
pub mut:
    tui &tui.Context = unsafe { nil }
}

pub fn new_app() &App {
    mut app := &App{
			user: 'root',
			initial : true
		}
    app.tui = tui.init(
        user_data: app
        event_fn: event
        frame_fn: frame
        hide_cursor: true
    )
    return app
}

pub fn (mut app App) run() ! {
	app.tui.run()! 
}

pub fn event(e &tui.Event, x voidptr) {
	if e.typ == .key_down && e.code == .escape {
			exit(0)
	}
}

pub fn frame(x voidptr) {
	mut app := unsafe { &App(x) }
	if app.initial == true {
		running := dbus.get_running_services() or {
        eprintln('Error: ${err}')
        return
    }
		 for service in running {
        println('Running: ${service.name} - ${service.description}')
    }
		app.initial = false
	}
	app.tui.clear()
	app.tui.set_bg_color(r: 63, g: 81, b: 181)
	app.tui.draw_rect(20, 6, 41, 10)
	app.tui.draw_text(24, 8, 'Hello from V!')
	app.tui.set_cursor_position(0, 0)

	app.tui.reset()
	app.tui.flush()
}
