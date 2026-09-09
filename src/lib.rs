use tauri::{
  plugin::{Builder, TauriPlugin},
  Manager, Runtime,
};

pub use models::*;

#[cfg(desktop)]
mod desktop;
#[cfg(mobile)]
mod mobile;

mod commands;
mod error;
mod models;
mod webproxy;

pub use error::{Error, Result};

#[cfg(desktop)]
use desktop::EdgeToEdge;
#[cfg(mobile)]
use mobile::EdgeToEdge;

/// Extensions to [`tauri::App`], [`tauri::AppHandle`] and [`tauri::Window`] to access the edge-to-edge APIs.
pub trait EdgeToEdgeExt<R: Runtime> {
  fn edge_to_edge(&self) -> &EdgeToEdge<R>;
}

impl<R: Runtime, T: Manager<R>> crate::EdgeToEdgeExt<R> for T {
  fn edge_to_edge(&self) -> &EdgeToEdge<R> {
    self.state::<EdgeToEdge<R>>().inner()
  }
}

/// Initializes the plugin.
pub fn init<R: Runtime>() -> TauriPlugin<R> {
  let builder = Builder::new("edge-to-edge")
    .invoke_handler(tauri::generate_handler![
      commands::get_safe_area_insets,
      commands::get_keyboard_info,
      commands::enable,
      commands::disable,
      commands::show_keyboard,
      commands::hide_keyboard
    ]);

  // Tauri runs plugin initialization scripts at document start on every
  // navigation. Keep this file under `src/` so Cargo includes it in the
  // published crate; `guest-js/` is the separately published npm API source.
  #[cfg(mobile)]
  let builder = builder.js_init_script(include_str!("webview-init.js"));

  // Register before Tauri creates any webviews. The logical proxy URL keeps
  // the original host/path so relative resources inside iframe documents keep
  // using the same proxy origin.
  let builder = webproxy::register(builder);

  builder
    .setup(|app, api| {
      #[cfg(mobile)]
      let edge_to_edge = mobile::init(app, api)?;
      #[cfg(desktop)]
      let edge_to_edge = desktop::init(app, api)?;
      app.manage(edge_to_edge);
      Ok(())
    })
    .build()
}
