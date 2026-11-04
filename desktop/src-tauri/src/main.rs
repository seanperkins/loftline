// The Windows and Linux shell: a window for the web front end, and one `loftline-core` process behind it. No CAM here: every
// request goes to the Swift core as one line of JSON, and its one-line reply comes back as it is.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::Mutex;
use tauri::State;

struct Core {
    child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
}

struct CoreState(Mutex<Option<Core>>);

/// `loftline-core` sits beside the app's executable in a bundle (Tauri's externalBin), or LOFTLINE_CORE names it in development.
fn core_path() -> Result<PathBuf, String> {
    if let Ok(path) = std::env::var("LOFTLINE_CORE") {
        return Ok(PathBuf::from(path));
    }
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let dir = exe.parent().ok_or("the app has no folder")?;
    let name = if cfg!(windows) { "loftline-core.exe" } else { "loftline-core" };
    Ok(dir.join(name))
}

fn start() -> Result<Core, String> {
    let path = core_path()?;
    let mut command = Command::new(&path);
    command.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::inherit());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let mut child = command.spawn().map_err(|e| format!("could not start {}: {e}", path.display()))?;
    let input = child.stdin.take().ok_or("no input to the core")?;
    let output = BufReader::new(child.stdout.take().ok_or("no output from the core")?);
    Ok(Core { child, input, output })
}

/// One request and its reply. The core is restarted on the next call after a crash; the front end reloads the file then, since
/// the project in memory went with it.
fn exchange(core: &mut Core, line: &str) -> Result<String, String> {
    writeln!(core.input, "{line}").map_err(|e| format!("the core stopped: {e}"))?;
    core.input.flush().map_err(|e| format!("the core stopped: {e}"))?;
    let mut reply = String::new();
    let n = core.output.read_line(&mut reply).map_err(|e| format!("the core stopped: {e}"))?;
    if n == 0 {
        return Err("the core stopped".into());
    }
    Ok(reply)
}

#[tauri::command]
async fn core_call(state: State<'_, CoreState>, request: String) -> Result<String, String> {
    let line = request.replace('\n', " ");
    let mut guard = state.0.lock().map_err(|_| "the core is unavailable".to_string())?;
    if guard.is_none() {
        *guard = Some(start()?);
    }
    let core = guard.as_mut().expect("just started");
    match exchange(core, &line) {
        Ok(reply) => Ok(reply),
        Err(e) => {
            let _ = core.child.kill();
            *guard = None;
            Err(e)
        }
    }
}

/// The file named on the command line (a double click on a .loftline), if any.
#[tauri::command]
fn opened_file() -> Option<String> {
    std::env::args().skip(1).find(|a| a.to_lowercase().ends_with(".loftline"))
}

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(CoreState(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![core_call, opened_file])
        .run(tauri::generate_context!())
        .expect("LoftLine could not start");
}
