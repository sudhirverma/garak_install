#!/usr/bin/env bash
# install_garak_ubuntu_fixed3.sh
# Robust installer + env-local garak reinstall + runtime deps fix (pyyaml)
# Usage: sudo ./install_garak_ubuntu_fixed3.sh

set -euo pipefail
IFS=$'\n\t'

LOG_DIR="${HOME:-/root}/garak_install_logs"
LOG_FILE="$LOG_DIR/install_$(date +%Y%m%d-%H%M%S).log"
GARAK_HOME="${HOME:-/root}/garak"
CONDA_KEYRING="/usr/share/keyrings/conda-archive-keyring.gpg"
CONDA_APT_SOURCE="/etc/apt/sources.list.d/conda.list"
TMP_BACKUP_DIR="/tmp/conda_repo_backup_$(date +%s)"
ENV_NAME="garak"
PYTHON_SPEC="python>=3.10,<=3.12"
EXPECTED_FPR="34161F5BF5EB1D4BFBBB8F0A8AEB4F8B29D82806"

mkdir -p "$LOG_DIR" "$TMP_BACKUP_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "=== Garak installer (fixed v3 + env-reinstall + deps) ==="
echo "Log: $LOG_FILE"
echo

run() { echo "+ $*"; "$@"; }

# If a conda.list exists, move it aside temporarily (avoid apt NO_PUBKEY blocking initial apt)
if [[ -f "$CONDA_APT_SOURCE" ]]; then
  echo "Found existing $CONDA_APT_SOURCE. Backing up to $TMP_BACKUP_DIR"
  run mv -f "$CONDA_APT_SOURCE" "$TMP_BACKUP_DIR/" || true
fi

# 1) Ensure base packages
run apt-get update -y
run apt-get install -y curl gnupg git unzip ca-certificates lsb-release

# 2) Download Anaconda key (idempotent)
TMPKEY="/tmp/anaconda.asc"
TEMP_DEARMOR="/tmp/conda-temp.gpg"

echo "Downloading Anaconda public key..."
run curl -fsSL https://repo.anaconda.com/pkgs/misc/gpgkeys/anaconda.asc -o "$TMPKEY"

echo "Dearmoring key..."
run gpg --dearmor --yes -o "$TEMP_DEARMOR" "$TMPKEY"

echo "Installing key to $CONDA_KEYRING..."
run install -o root -g root -m 644 "$TEMP_DEARMOR" "$CONDA_KEYRING"
rm -f "$TMPKEY" "$TEMP_DEARMOR"

# 3) Parse fingerprint robustly using --with-colons
echo "Reading fingerprint from keyring..."
FPR_LINE=$(gpg --no-default-keyring --keyring "$CONDA_KEYRING" --with-colons --fingerprint 2>/dev/null | awk -F: '$1=="fpr" {print $10; exit}')
if [[ -z "$FPR_LINE" ]]; then
  echo "ERROR: could not read fingerprint from $CONDA_KEYRING" >&2
  # restore backup if present
  if [[ -f "$TMP_BACKUP_DIR/$(basename $CONDA_APT_SOURCE)" ]]; then
    run mv -f "$TMP_BACKUP_DIR/$(basename $CONDA_APT_SOURCE)" "$CONDA_APT_SOURCE"
  fi
  exit 1
fi

echo "Found fingerprint: $FPR_LINE"
if [[ "${FPR_LINE^^}" != "${EXPECTED_FPR^^}" ]]; then
  echo "ERROR: fingerprint mismatch!" >&2
  echo " Expected: $EXPECTED_FPR" >&2
  echo " Found:    $FPR_LINE" >&2
  echo "Aborting. Restoring any backed-up apt source." >&2
  if [[ -f "$TMP_BACKUP_DIR/$(basename $CONDA_APT_SOURCE)" ]]; then
    run mv -f "$TMP_BACKUP_DIR/$(basename $CONDA_APT_SOURCE)" "$CONDA_APT_SOURCE"
  fi
  exit 1
fi
echo "Fingerprint matches expected value."

# 4) Write apt source referencing the keyring
cat > /tmp/conda.list.tmp <<EOF
# Anaconda conda apt repo (managed by installer)
deb [arch=amd64 signed-by=$CONDA_KEYRING] https://repo.anaconda.com/pkgs/misc/debrepo/conda stable main
EOF
run mv -f /tmp/conda.list.tmp "$CONDA_APT_SOURCE"
echo "Wrote $CONDA_APT_SOURCE"

# 5) Update apt and install conda package
run apt-get update -y
run apt-get install -y conda

# 6) Source conda profile if available
CONDA_PROFILE="/opt/conda/etc/profile.d/conda.sh"
if [[ -f "$CONDA_PROFILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONDA_PROFILE"
  echo "Sourced $CONDA_PROFILE"
else
  echo "Warning: $CONDA_PROFILE not found after installing conda." >&2
fi

echo "Conda version: $(conda -V || true)"

# 7) Create garak env if not exists
if conda env list | awk '{print $1}' | grep -xq "^$ENV_NAME$"; then
  echo "Conda env '$ENV_NAME' already exists; skipping create."
else
  run conda create --name "$ENV_NAME" "$PYTHON_SPEC" -y
fi

# 8) Activate env and prep Python tooling
# shellcheck source=/dev/null
source "$CONDA_PROFILE"
conda activate "$ENV_NAME"
run python -m pip install --upgrade pip setuptools wheel
run python -m pip install ipykernel || true

# 9) Clone the canonical repo into GARAK_HOME for record (optional)
if [[ -d "$GARAK_HOME" ]]; then
  echo "Updating existing repo at $GARAK_HOME"
  run git -C "$GARAK_HOME" fetch --all || true
  run git -C "$GARAK_HOME" pull --ff-only || true
else
  run git clone https://github.com/NVIDIA/garak.git "$GARAK_HOME"
fi

# 10) ALSO clone a fresh copy to /tmp and force-reinstall into the active env (ensures editable package in this env)
echo "Preparing fresh clone in /tmp/garak for env-local editable install..."
run rm -rf /tmp/garak || true
run git clone https://github.com/NVIDIA/garak.git /tmp/garak
run cd /tmp/garak

# 10a) Install common runtime deps that Garak expects (fix missing 'yaml' etc.)
# Install PyYAML (yaml) and other commonly-needed deps. If garak later needs more,
# the verification below will show the missing module name and the script can be extended.
echo "Installing runtime dependencies (pyyaml etc.) into the garak env..."
run python -m pip install --no-warn-script-location pyyaml

# Optional: if the repo provides a requirements file, install it too (best-effort)
if [[ -f "/tmp/garak/requirements.txt" ]]; then
  echo "Found requirements.txt; installing extras..."
  run python -m pip install --no-warn-script-location -r /tmp/garak/requirements.txt || true
fi

# 11) Install garak into active conda env (editable, force reinstall) -- no sudo
echo "Installing garak into active conda env (editable, force reinstall) -- no sudo"
run python -m pip install --no-deps --force-reinstall -e .

# 12) Final install of GARAK_HOME (kept as record)
if [[ -d "$GARAK_HOME" ]]; then
  echo "Keeping $GARAK_HOME as the repository record (not overwriting)."
fi

# 13) Verify installation: import + list probes
echo "Verifying 'garak' package import and CLI..."
python - <<'PY'
import sys, traceback
try:
    import garak
    print("GARAK IMPORT OK ->", getattr(garak, '__file__', None))
except Exception as e:
    print("GARAK IMPORT FAILED:", type(e).__name__, e)
    traceback.print_exc()
    sys.exit(2)
PY

# Try CLI probe listing (use python -m fallback if console script not on PATH)
if command -v garak >/dev/null 2>&1; then
  echo "Trying garak --version"
  garak --version || true
  echo "Trying garak --list_probes (short)"
  garak --list_probes | sed -n '1,60p' || true
else
  echo "'garak' console script not found in PATH; trying python -m garak.__main__"
  python -m garak.__main__ --list_probes | sed -n '1,60p' || true
fi

echo
echo "Installation complete. Log: $LOG_FILE"
echo "Next steps: source $CONDA_PROFILE && conda activate $ENV_NAME ; garak --list_probes"
exit 0

