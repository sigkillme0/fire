class Fire < Formula
  desc "Run Firecracker microVMs on macOS Apple Silicon via Lima"
  homepage "https://github.com/sigkillme0/firecracker-macos"
  url "https://github.com/sigkillme0/firecracker-macos/archive/refs/tags/v1.0.0.tar.gz"
  sha256 "3ff46dfd52fcf668d045c69bafd0417c8307024c771a2b6a2d7d25f8b24771a8"
  license "MIT"
  head "https://github.com/sigkillme0/firecracker-macos.git", branch: "main"

  depends_on :macos
  depends_on arch: :arm64
  depends_on "jq"
  depends_on "lima"

  def install
    # preserve full directory structure in libexec so fire's
    # symlink-resolving path logic finds lib/fcctl and lima/firecracker.yaml
    libexec.install "bin", "lib", "lima"
    chmod 0755, libexec/"bin/fire"
    chmod 0755, libexec/"lib/fcctl"

    # symlink the single user-facing binary into homebrew's bin
    bin.install_symlink libexec/"bin/fire"
  end

  def caveats
    <<~EOS
      fire requires Apple Silicon M3 or later for nested virtualization.

      to get started:
        fire setup           # one-time: creates lima VM + downloads firecracker (~5 min)
        fire create myvm     # create a microVM
        fire start myvm      # boot it (~6s)
        fire ssh myvm        # you're in

      to uninstall completely:
        fire vm delete       # delete the lima VM and all microVMs
        brew uninstall fire
    EOS
  end

  test do
    assert_match "run firecracker microVMs on macOS", shell_output("#{bin}/fire help")
    assert_match "fire", shell_output("#{bin}/fire version 2>&1", 0)
  end
end
