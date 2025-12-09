class Oshen < Formula
  desc "A terminal shell that's just tryin' to be fun."
  homepage "https://github.com/lostintangent/oshen"
  version File.read(File.expand_path("../VERSION", __dir__)).strip
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/lostintangent/oshen/releases/latest/download/oshen-macos-arm64.tar.gz"
      sha256 "SHA_MACOS_ARM64"
    end
    on_intel do
      url "https://github.com/lostintangent/oshen/releases/latest/download/oshen-macos-x86_64.tar.gz"
      sha256 "SHA_MACOS_X86_64"
    end
  end

  on_linux do
    url "https://github.com/lostintangent/oshen/releases/latest/download/oshen-linux-x86_64.tar.gz"
    sha256 "SHA_LINUX_X86_64"
  end

  def install
    bin.install "oshen"
  end

  test do
    assert_equal "hello", shell_output("#{bin}/oshen -c 'echo hello'").strip
  end
end
