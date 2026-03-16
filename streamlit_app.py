import json
import os
import shutil
import subprocess
import uuid
from datetime import datetime
from pathlib import Path

import streamlit as st


ROOT = Path(__file__).resolve().parent
R_SCRIPT = ROOT / "generate_future_weather.R"
DEFAULT_OUTPUT_DIR = Path(os.environ.get("FUTURE_WEATHER_OUTPUT_DIR", "/tmp/future-weather-runs"))
OUTPUT_DIR = DEFAULT_OUTPUT_DIR if DEFAULT_OUTPUT_DIR.is_absolute() else (ROOT / DEFAULT_OUTPUT_DIR)
SCENARIOS = ["ssp126", "ssp245", "ssp370", "ssp585"]
MAX_RUN_DIRS_PER_SESSION = 3


def get_session_dir() -> Path:
    if "session_id" not in st.session_state:
        st.session_state.session_id = uuid.uuid4().hex
    return OUTPUT_DIR / st.session_state.session_id


def find_rscript_from_registry() -> str | None:
    if os.name != "nt":
        return None

    try:
        import winreg
    except ImportError:
        return None

    registry_locations = [
        (winreg.HKEY_LOCAL_MACHINE, r"Software\R-core\R"),
        (winreg.HKEY_LOCAL_MACHINE, r"Software\WOW6432Node\R-core\R"),
        (winreg.HKEY_CURRENT_USER, r"Software\R-core\R"),
    ]

    for hive, subkey in registry_locations:
        try:
            with winreg.OpenKey(hive, subkey) as key:
                install_path, _ = winreg.QueryValueEx(key, "InstallPath")
        except OSError:
            continue

        candidate = Path(install_path) / "bin" / "Rscript.exe"
        if candidate.exists():
            return str(candidate)

    return None


def resolve_rscript() -> str:
    configured = os.environ.get("RSCRIPT_PATH")
    if configured:
        candidate = Path(configured)
        if candidate.exists():
            return str(candidate)

    rstudio_path = os.environ.get("RSTUDIO_PATH")
    if rstudio_path:
        candidate = Path(rstudio_path)
        if candidate.exists():
            registry_match = find_rscript_from_registry()
            if registry_match:
                return registry_match

    on_path = shutil.which("Rscript")
    if on_path:
        return on_path

    registry_match = find_rscript_from_registry()
    if registry_match:
        return registry_match

    common_windows_paths = [
        Path(r"C:\Program Files\R"),
        Path(r"C:\Program Files\R\R-4.4.0\bin\Rscript.exe"),
        Path(r"C:\Program Files\R\R-4.4.1\bin\Rscript.exe"),
        Path(r"C:\Program Files\R\R-4.4.2\bin\Rscript.exe"),
        Path(r"C:\Program Files\R\R-4.5.0\bin\Rscript.exe"),
        Path(r"C:\Program Files\R\R-4.5.1\bin\Rscript.exe"),
    ]

    for path in common_windows_paths:
        if path.is_file():
            return str(path)
        if path.is_dir():
            versions = sorted(path.glob(r"R-*\bin\Rscript.exe"), reverse=True)
            if versions:
                return str(versions[0])

    raise FileNotFoundError(
        "Rscript was not found. Install R, or set RSCRIPT_PATH to Rscript.exe. "
        "RStudio alone is not enough because it cannot run this backend script directly."
    )


@st.cache_data(show_spinner=False)
def load_cities(rscript_path: str) -> list[str]:
    cmd = [rscript_path, str(R_SCRIPT), "--list-cities"]
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=600)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or "Failed to load city list from the R pipeline.")
    return json.loads(proc.stdout)


def latest_run_dir(session_dir: Path) -> Path | None:
    run_dirs = sorted(session_dir.glob("Future_*"), key=lambda p: p.stat().st_mtime, reverse=True)
    return run_dirs[0] if run_dirs else None


def prune_old_runs(session_dir: Path) -> None:
    run_dirs = sorted(session_dir.glob("Future_*"), key=lambda p: p.stat().st_mtime, reverse=True)
    for old_dir in run_dirs[MAX_RUN_DIRS_PER_SESSION:]:
        shutil.rmtree(old_dir, ignore_errors=True)


def format_run_timestamp(run_dir: Path) -> str:
    try:
        return datetime.fromtimestamp(run_dir.stat().st_mtime).strftime("%Y-%m-%d %H:%M:%S")
    except OSError:
        return "unknown time"


def read_manifest(run_dir: Path) -> tuple[dict, Path]:
    manifest_path = run_dir / "result.json"
    if not manifest_path.exists():
        raise FileNotFoundError("Run finished, but the result manifest is missing.")

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    zip_name = manifest.get("zip_name")
    if not zip_name:
        raise ValueError("Manifest is missing the ZIP filename.")

    zip_path = run_dir / zip_name
    if not zip_path.exists():
        raise FileNotFoundError("Manifest was found, but the ZIP file is missing.")

    return manifest, zip_path


st.set_page_config(page_title="Future Weather Generator", layout="centered")
st.title("Future Weather Generator")
st.caption("The app uses the original R-based weather morphing pipeline, wrapped in a safer Streamlit flow.")
st.caption(f"Run artifacts are stored in: `{OUTPUT_DIR}`")

OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
session_dir = get_session_dir()
session_dir.mkdir(parents=True, exist_ok=True)

try:
    rscript_path = resolve_rscript()
    city_options = load_cities(rscript_path)
except Exception as exc:
    st.error(f"Unable to load the city list: {exc}")
    st.info(
        "If R is installed, set an environment variable like "
        "`RSCRIPT_PATH=C:\\Program Files\\R\\R-4.4.1\\bin\\Rscript.exe` "
        "or add `Rscript` to your PATH."
    )
    st.stop()

with st.form("future_weather_form"):
    city = st.selectbox("City", city_options, index=city_options.index("Ahmedabad (GJ)") if "Ahmedabad (GJ)" in city_options else 0)
    year = st.selectbox("Future year", list(range(2030, 2105, 5)), index=4)
    scenario = st.selectbox("Scenario", SCENARIOS, index=1)
    submitted = st.form_submit_button("Generate Future Weather")

if submitted:
    cmd = [
        rscript_path,
        str(R_SCRIPT),
        "--city",
        city,
        "--year",
        str(year),
        "--scenario",
        scenario,
        "--output_dir",
        str(session_dir),
    ]

    with st.status("Running weather generation...", expanded=True) as status:
        proc = subprocess.run(cmd, capture_output=True, text=True, check=False, timeout=7200)

        if proc.stdout:
            st.code(proc.stdout)
        if proc.stderr:
            st.code(proc.stderr)

        if proc.returncode != 0:
            status.update(label="Generation failed", state="error")
            st.error("The weather generation pipeline failed. Review the run log above.")
        else:
            status.update(label="Generation complete", state="complete")
            prune_old_runs(session_dir)
            run_dir = latest_run_dir(session_dir)
            if run_dir is None:
                st.error("The run completed, but no output folder was created.")
            else:
                try:
                    manifest, zip_path = read_manifest(run_dir)
                except Exception as exc:
                    st.error(str(exc))
                else:
                    st.success(
                        f"Generated {len(manifest['future_files'])} future EPW files for "
                        f"{manifest['city']} ({manifest['scenario']} {manifest['year']})."
                    )
                    st.write(f"Completed at: {format_run_timestamp(run_dir)}")
                    st.download_button(
                        label="Download ZIP",
                        data=zip_path.read_bytes(),
                        file_name=f"{manifest['city'].replace(' ', '_')}_{manifest['year']}_{manifest['scenario']}.zip",
                        mime="application/zip",
                    )

last_run = latest_run_dir(session_dir)
if last_run is not None:
    try:
        manifest, zip_path = read_manifest(last_run)
    except Exception:
        pass
    else:
        st.divider()
        st.subheader("Latest Result")
        st.write(f"{manifest['city']} | {manifest['scenario']} | {manifest['year']}")
        st.write(f"Completed at: {format_run_timestamp(last_run)}")
        st.download_button(
            label="Download Latest ZIP",
            data=zip_path.read_bytes(),
            file_name=f"{manifest['city'].replace(' ', '_')}_{manifest['year']}_{manifest['scenario']}.zip",
            mime="application/zip",
            key="download_latest_zip",
        )
