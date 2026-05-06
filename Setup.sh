#!/bin/bash

# --- 1. Initialization & Sudo Heartbeat ---
failed=()

# Check for sudo immediately
if ! sudo -v; then
    echo "❌ This script requires sudo privileges."
    exit 1
fi

# Keep sudo alive in the background
while true; do sudo -n true; sleep 60; kill -0 "$$" || exit; done 2>/dev/null &
SUDO_PID=$!
trap "kill $SUDO_PID" EXIT

# Determine the actual user (not root)
REAL_USER=${SUDO_USER:-$USER}
USER_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

echo "[+] Initializing system and dependencies..."
# Added 'software-properties-common' to ensure add-apt-repository works
sudo apt update && sudo apt install -y apt-transport-https curl wget gpg unzip file software-properties-common

# PRE-EMPTIVE SNAP REMOVAL (Prevents Apt/Snap conflicts for Firefox)
echo "[+] Removing Firefox Snap..."
sudo snap remove firefox 2>/dev/null

# --- 2. Repositories & Keyrings ---
echo "[+] Configuring Repositories..."
sudo mkdir -p /etc/apt/keyrings /usr/share/keyrings

# Signal
wget -qO- https://updates.signal.org/desktop/apt/keys.asc | gpg --dearmor | sudo tee /usr/share/keyrings/signal-desktop-keyring.gpg > /dev/null
echo 'deb [arch=amd64 signed-by=/usr/share/keyrings/signal-desktop-keyring.gpg] https://updates.signal.org/desktop/apt xenial main' | sudo tee /etc/apt/sources.list.d/signal-xenial.list

# ProtonVPN
wget https://repo.protonvpn.com/debian/dists/stable/main/binary-all/protonvpn-stable-release_1.0.8_all.deb
sudo dpkg -i ./protonvpn-stable-release_1.0.8_all.deb && sudo apt update

# Quickemu PPA
sudo apt-add-repository -y ppa:flexiondotorg/quickemu

# Element
wget -qO- https://packages.element.io/debian/element-io-archive-keyring.gpg | sudo tee /usr/share/keyrings/element-io-archive-keyring.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/element-io-archive-keyring.gpg] https://packages.element.io/debian/ default main" | sudo tee /etc/apt/sources.list.d/element-io.list

# Syncthing
curl -sL https://syncthing.net/release-key.gpg | sudo gpg --dearmor -o /etc/apt/keyrings/syncthing-archive-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/syncthing-archive-keyring.gpg] https://apt.syncthing.net/ syncthing stable-v2" | sudo tee /etc/apt/sources.list.d/syncthing.list

# Brave
curl -fsSLo brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
sudo mv brave-browser-archive-keyring.gpg /usr/share/keyrings/
curl -fsSLo brave-browser.sources https://brave-browser-apt-release.s3.brave.com/brave-browser.sources
sudo mv brave-browser.sources /etc/apt/sources.list.d/

# Mozilla Firefox Pinning (Crucial for Ubuntu 22.04/24.04)
wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O- | sudo tee /etc/apt/keyrings/packages.mozilla.org.asc > /dev/null
cat <<EOF | sudo tee /etc/apt/sources.list.d/mozilla.sources
Types: deb
URIs: https://packages.mozilla.org/apt
Suites: mozilla
Components: main
Signed-By: /etc/apt/keyrings/packages.mozilla.org.asc
EOF

echo '
Package: *
Pin: origin packages.mozilla.org
Pin-Priority: 1000

Package: firefox*
Pin: release o=Ubuntu
Pin-Priority: -1
' | sudo tee /etc/apt/preferences.d/mozilla > /dev/null

sudo apt-get -o DPkg::Lock::Timeout=60 update


# --- 3. Configuration & Package Lists ---
APT_PKGS=(
    vlc gimp thunderbird bridge-utils qpdf quickgui btop 
    ffmpegthumbnailer fastfetch flatpak gnome-software-plugin-flatpak 
    adb virt-manager 7zip grsync qemu-system-x86 ffmpeg libvirt-daemon-system 
    git intel-gpu-tools pdfcrack calibre signal-desktop
    proton-vpn-gnome-desktop quickemu libopengl0 firefox gnome-tweaks
    element-desktop syncthing brave-browser gnome-sushi i965-va-driver vainfo remmina
)

FLATPAK_PKGS=(
    com.mattjakeman.ExtensionManager 
    it.mijorus.gearlever 
    net.pcsx2.PCSX2 
    org.kde.kasts 
    org.kde.kleopatra
    com.moonlight_stream.Moonlight
)

# --- 4. Helper Functions ---

is_installed() { dpkg -l "$1" 2>/dev/null | grep -q "^ii"; }

get_latest_github_url() {
    local repo=$1
    local pattern=$2
    # Enhanced grep to specifically target the browser_download_url
    local url=$(curl -s "https://api.github.com/repos/$repo/releases/latest" | grep "browser_download_url" | grep "$pattern" | head -n 1 | cut -d : -f 2,3 | tr -d \" | xargs)
    echo "$url"
}

download_file() {
    local url=$1
    local output=$2
    local expected_type=$3
    
    if [ -z "$url" ]; then
        echo "❌ URL for $output is empty. Skipping."
        failed+=("$output (URL not found)")
        return 1
    fi

    echo "[+] Downloading $output..."
    if wget -q --show-progress -O "$output" "$url"; then
        if file "$output" | grep -qi "$expected_type"; then
            return 0
        else
            echo "❌ $output is not a valid $expected_type."
            rm -f "$output"
            failed+=("$output (invalid format)")
            return 1
        fi
    else
        echo "❌ Failed to download $output"
        rm -f "$output"
        failed+=("$output (download failed)")
        return 1
    fi
}


sudo apt-get -o DPkg::Lock::Timeout=60 update

# --- 5. Installation Logic ---

for pkg in "${APT_PKGS[@]}"; do
    if is_installed "$pkg"; then
        echo "[-] $pkg (already installed)"
    else
        echo "[+] Installing $pkg..."
        sudo apt-get -o DPkg::Lock::Timeout=60 install -y "$pkg" || failed+=("$pkg (apt)")
    fi
done

sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
for pkg in "${FLATPAK_PKGS[@]}"; do
    echo "[+] Installing $pkg (Flatpak)..."
    sudo flatpak install -y flathub "$pkg" || failed+=("$pkg (flatpak)")
done

sudo usermod -aG libvirt "$REAL_USER"

# --- 6. Standalone .deb Downloads ---
echo "[+] Handling standalone installers..."
TEMP_DEB=$(mktemp -d)
cd "$TEMP_DEB"

download_file "$(get_latest_github_url "localsend/localsend" "linux-x86-64.deb")" "localsend.deb" "Debian"
download_file "$(get_latest_github_url "Heroic-Games-Launcher/HeroicGamesLauncher" "amd64.deb")" "heroic.deb" "Debian"
download_file "https://github.com/lutris/lutris/releases/download/v0.5.22/lutris_0.5.22_all.deb" "lutris.deb" "Debian"
download_file "https://vault.bitwarden.com/download/?app=desktop&platform=linux&variant=deb" "bitwarden.deb" "Debian"
download_file "https://github.com/obsidianmd/obsidian-releases/releases/download/v1.12.7/obsidian_1.12.7_amd64.deb" "Debian"
download_file "https://updates.safing.io/latest/linux_amd64/packages/Portmaster_2.1.7_amd64.deb" "portmaster.deb" "Debian"
download_file "https://discord.com/api/download?platform=linux&format=deb" "discord.deb" "Debian"
download_file "https://code.visualstudio.com/sha/download?build=stable&os=linux-deb-x64" "vscode.deb" "Debian"
download_file "https://cdn.fastly.steamstatic.com/client/installer/steam.deb" "steam.deb" "Debian"
download_file "https://proton.me/download/authenticator/linux/ProtonAuthenticator_1.1.4_amd64.deb" "ProtonAuthenticator.deb" "Debian"
download_file "https://github.com/quickemu-project/quickgui/releases/download/1.2.10/quickgui-1.2.10+1-linux.deb" "quickgui.deb" "Debian"

if ls *.deb >/dev/null 2>&1; then
    sudo apt-get install -y ./*.deb || failed+=("Standalone .deb batch")
fi
rm -rf "$TEMP_DEB"

# --- 7. Snaps, AppImages & Tweaks ---
sudo snap install gramps

sudo systemctl mask tpm2.target
sudo apt remove intel-media-va-driver

# AppImage Handling
APP_DIR="$USER_HOME/Apps"
sudo -u "$REAL_USER" mkdir -p "$APP_DIR"
cd "$APP_DIR"

echo "[+] Fetching AppImages..."
sudo -u "$REAL_USER" wget -qO Joplin.AppImage "$(get_latest_github_url "laurent22/joplin" "AppImage")"
sudo -u "$REAL_USER" wget -qO Cryptomator.AppImage "$(get_latest_github_url "cryptomator/cryptomator" "x86_64.AppImage")"
sudo -u "$REAL_USER" wget -qO Tutanota.AppImage "https://app.tuta.com/desktop/tutanota-desktop-linux.AppImage"

# iDescriptor (Logic reinforced for ZIP extraction)
IDESC_URL=$(get_latest_github_url "iDescriptor/iDescriptor" "AppImage.zip")
if [ -n "$IDESC_URL" ]; then
    sudo -u "$REAL_USER" wget -qO iDescriptor.zip "$IDESC_URL"
    sudo -u "$REAL_USER" unzip -o iDescriptor.zip
    sudo -u "$REAL_USER" rm iDescriptor.zip
fi

chmod +x *.AppImage
# Final ownership sweep to ensure $REAL_USER owns everything in ~/Apps
sudo chown -R "$REAL_USER:$REAL_USER" "$APP_DIR"

# --- 8. Summary ---
echo -e "\n===== Install Summary ====="
if [ ${#failed[@]} -eq 0 ]; then
    echo "✅ System configured successfully!"
else
    echo "❌ Failures detected:"
    for pkg in "${failed[@]}"; do echo "  - $pkg"; done
fi

echo -e "\nNote: User added to 'libvirt' group. Reboot recommended."
