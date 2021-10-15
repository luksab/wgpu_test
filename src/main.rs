use imgui::*;
use imgui_wgpu::{Renderer, RendererConfig, Texture, TextureConfig};
use std::time::{Instant, SystemTime};
use wgpu::Extent3d;
use winit::event::{ElementState, Event, KeyboardInput, VirtualKeyCode, WindowEvent};
use winit::event_loop::{ControlFlow, EventLoop};

mod camera;
mod instance;
mod model;
mod texture;

mod scene;
mod state;
use state::State;

mod demo3d;

mod game_of_life;

fn main() {
    env_logger::init();
    let event_loop = EventLoop::new();
    // get the title at compile time from env
    let title = env!("CARGO_PKG_NAME");
    let window = winit::window::WindowBuilder::new()
        .with_title(title)
        .build(&event_loop)
        .unwrap();

    // initialize a state
    let mut state = pollster::block_on(State::new(window));

    // create scenes and push into state
    {
        let game_of_life =
            pollster::block_on(game_of_life::GameOfLife::new(&state.device, &state.config));
        state.scenes.push(Box::new(game_of_life));

        let demo = pollster::block_on(demo3d::Demo3d::new(
            &state.device,
            &state.queue,
            &state.config,
        ));

        state.scenes.push(Box::new(demo));
    }

    let mut last_render_time = std::time::Instant::now();
    let mut last_sec = SystemTime::now();
    let mut frames_since_last_sec = 0;
    let mut fps = 0;

    // Set up dear imgui
    let mut imgui = imgui::Context::create();
    let mut platform = imgui_winit_support::WinitPlatform::init(&mut imgui);
    platform.attach_window(
        imgui.io_mut(),
        &state.window,
        imgui_winit_support::HiDpiMode::Default,
    );
    // don't save imgui prefrences
    imgui.set_ini_filename(None);

    // Set font for imgui
    {
        let hidpi_factor = state.window.scale_factor();
        println!("scaling factor: {}", hidpi_factor);

        let font_size = (13.0 * hidpi_factor) as f32;
        imgui.io_mut().font_global_scale = (1.0 / hidpi_factor) as f32;

        imgui.fonts().add_font(&[FontSource::DefaultFontData {
            config: Some(imgui::FontConfig {
                oversample_h: 1,
                pixel_snap_h: true,
                size_pixels: font_size,
                ..Default::default()
            }),
        }]);
    }

    //
    // Set up dear imgui wgpu renderer
    //

    let mut renderer = {
        let renderer_config = RendererConfig {
            texture_format: state.config.format,
            ..Default::default()
        };
        Renderer::new(&mut imgui, &state.device, &state.queue, renderer_config)
    };

    let mut last_frame = Instant::now();

    let mut last_cursor = None;

    let mut window_render_size: [f32; 2] = [640.0, 480.0];

    // Stores a texture for displaying with imgui::Image(),
    // also as a texture view for rendering into it
    let window_texture_id = {
        let texture_config = TextureConfig {
            size: wgpu::Extent3d {
                width: window_render_size[0] as u32,
                height: window_render_size[1] as u32,
                ..Default::default()
            },
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            ..Default::default()
        };

        let texture = Texture::new(&state.device, &renderer, texture_config);
        renderer.textures.insert(texture)
    };

    let depth_texture_id = {
        let depth_texture = Texture::new(
            &state.device,
            &renderer,
            TextureConfig {
                size: wgpu::Extent3d {
                    width: window_render_size[0] as u32,
                    height: window_render_size[1] as u32,
                    ..Default::default()
                },
                usage: wgpu::TextureUsages::TEXTURE_BINDING,
                format: Some(wgpu::TextureFormat::Depth32Float),
                ..Default::default()
            },
        );
        renderer.textures.insert(depth_texture)
    };

    event_loop.run(move |event, _, control_flow| {
        if last_sec.elapsed().unwrap().as_secs() > 1 {
            last_sec = SystemTime::now();
            fps = frames_since_last_sec;
            // println!("fps: {}", frames_since_last_sec);
            frames_since_last_sec = 0;
        }

        *control_flow = ControlFlow::Poll;
        match event {
            Event::MainEventsCleared => state.window.request_redraw(),
            Event::WindowEvent {
                ref event,
                window_id,
            } if window_id == state.window.id() => {
                state.input(event);
                match event {
                    WindowEvent::CloseRequested
                    | WindowEvent::KeyboardInput {
                        input:
                            KeyboardInput {
                                state: ElementState::Pressed,
                                virtual_keycode: Some(VirtualKeyCode::Escape),
                                ..
                            },
                        ..
                    } => *control_flow = ControlFlow::Exit,
                    WindowEvent::Resized(physical_size) => {
                        state.resize(*physical_size, None);
                    }
                    WindowEvent::ScaleFactorChanged {
                        new_inner_size,
                        scale_factor,
                        ..
                    } => {
                        state.resize(**new_inner_size, Some(scale_factor));
                    }
                    _ => {}
                }
            }
            Event::RedrawEventsCleared => {
                let now = Instant::now();
                imgui.io_mut().update_delta_time(now - last_frame);
                last_frame = now;

                // get entire window as texture
                let frame = match state.surface.get_current_texture() {
                    Ok(frame) => frame,
                    Err(e) => {
                        eprintln!("dropped frame: {:?}", e);
                        return;
                    }
                };
                platform
                    .prepare_frame(imgui.io_mut(), &state.window)
                    .expect("Failed to prepare frame");
                let ui = imgui.frame();

                let view = frame
                    .texture
                    .create_view(&wgpu::TextureViewDescriptor::default());

                // Render normally at background
                let now = std::time::Instant::now();
                let dt = now - last_render_time;
                last_render_time = now;
                state.update(dt);
                let depth_texture = texture::Texture::create_depth_texture(
                    &state.device,
                    &wgpu::SurfaceConfiguration {
                        usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                        format: state.surface.get_preferred_format(&state.adapter).unwrap(),
                        width: state.size.width,
                        height: state.size.height,
                        present_mode: wgpu::PresentMode::Fifo,
                    },
                    "depth_texture",
                );

                // Render demo3d
                match state.render(&view, Some(&depth_texture.view), 1) {
                    Ok(_) => {
                        frames_since_last_sec += 1;
                    }
                    // Reconfigure the surface if lost
                    Err(wgpu::SurfaceError::Lost) => state.resize(state.size, None),
                    // The system is out of memory, we should probably quit
                    Err(wgpu::SurfaceError::OutOfMemory) => *control_flow = ControlFlow::Exit,
                    // All other errors (Outdated, Timeout) should be resolved by the next frame
                    Err(e) => eprintln!("{:?}", e),
                }

                imgui::Window::new("Hello too")
                    .size([400.0, 200.0], Condition::FirstUseEver)
                    .position([600.0, 200.0], Condition::FirstUseEver)
                    .build(&ui, || {
                        ui.text(format!("Framerate: {:?}", fps));
                    });

                // Store the new size of Image() or None to indicate that the window is collapsed.
                let mut new_window_size: Option<[f32; 2]> = None;
                imgui::Window::new("Hello World")
                    .size([1024.0, 1024.0], Condition::FirstUseEver)
                    .build(&ui, || {
                        // new_example_size = Some(ui.content_region_avail());
                        // ui.text("Hello world!");
                        // ui.text("This...is...imgui-rs on WGPU!");
                        // ui.separator();
                        // let mouse_pos = ui.io().mouse_pos;
                        // ui.text(format!(
                        //     "Mouse Position: ({:.1},{:.1})",
                        //     mouse_pos[0], mouse_pos[1]
                        // ));
                        new_window_size = Some(ui.content_region_avail());
                        imgui::Image::new(window_texture_id, new_window_size.unwrap()).build(&ui);
                    });

                if let Some(size) = new_window_size {
                    // Resize render target, which is optional
                    if size != window_render_size && size[0] >= 1.0 && size[1] >= 1.0 {
                        window_render_size = size;
                        let scale = &ui.io().display_framebuffer_scale;
                        let texture_config = TextureConfig {
                            size: Extent3d {
                                width: (window_render_size[0] * scale[0]) as u32,
                                height: (window_render_size[1] * scale[1]) as u32,
                                ..Default::default()
                            },
                            usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                                | wgpu::TextureUsages::TEXTURE_BINDING,
                            ..Default::default()
                        };
                        renderer.textures.replace(
                            window_texture_id,
                            Texture::new(&state.device, &renderer, texture_config),
                        );
                        let depth_texture = Texture::new(
                            &state.device,
                            &renderer,
                            TextureConfig {
                                size: wgpu::Extent3d {
                                    width: (window_render_size[0] * scale[0]) as u32,
                                    height: (window_render_size[1] * scale[1]) as u32,
                                    ..Default::default()
                                },
                                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                                    | wgpu::TextureUsages::TEXTURE_BINDING,
                                format: Some(wgpu::TextureFormat::Depth32Float),
                                ..Default::default()
                            },
                        );
                        renderer.textures.replace(depth_texture_id, depth_texture);
                    }

                    // Only render contents if the window is not collapsed
                    match state.render(
                        &renderer.textures.get(window_texture_id).unwrap().view(),
                        Some(&renderer.textures.get(depth_texture_id).unwrap().view()),
                        0,
                    ) {
                        Ok(_) => {
                            frames_since_last_sec += 1;
                        }
                        // Reconfigure the surface if lost
                        Err(wgpu::SurfaceError::Lost) => {
                            state.resize(state.size, None);
                        }
                        // The system is out of memory, we should probably quit
                        Err(wgpu::SurfaceError::OutOfMemory) => *control_flow = ControlFlow::Exit,
                        // All other errors (Outdated, Timeout) should be resolved by the next frame
                        Err(e) => eprintln!("{:?}", e),
                    }
                }

                // Actually render imgui ui
                let mut encoder: wgpu::CommandEncoder = state
                    .device
                    .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
                {
                    if last_cursor != Some(ui.mouse_cursor()) {
                        last_cursor = Some(ui.mouse_cursor());
                        platform.prepare_render(&ui, &state.window);
                    }

                    let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                        label: None,
                        color_attachments: &[wgpu::RenderPassColorAttachment {
                            view: &view,
                            resolve_target: None,
                            ops: wgpu::Operations {
                                load: wgpu::LoadOp::Load, // Do not clear
                                // load: wgpu::LoadOp::Clear(clear_color),
                                store: true,
                            },
                        }],
                        depth_stencil_attachment: None,
                    });

                    renderer
                        .render(ui.render(), &state.queue, &state.device, &mut rpass)
                        .expect("Rendering imgui failed");
                }
                state.queue.submit(Some(encoder.finish()));

                frame.present();
            }
            _ => {}
        }
        // Let imgui handle the event
        platform.handle_event(imgui.io_mut(), &state.window, &event);
    });
}
