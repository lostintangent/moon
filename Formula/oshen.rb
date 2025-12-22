class Oshen < Formula
  desc "A terminal shell that's just tryin' to be fun."
  homepage "https://github.com/lostintangent/oshen"
  version File.read(File.expand_path("../scripts/VERSION", __dir__)).strip
  license "MIT"

  on_macos do
    on_arm do
      url "https://github.com/lostintangent/oshen/releases/latest/download/oshen-macos-arm64.tar.gz"
      sha256 "d534809790c34207e9908dfd26fa6b023184090c3aa098167f9a35e1286eb337"
    end
    on_intel do
      url "https://github.com/lostintangent/oshen/releases/latest/download/oshen-macos-x86_64.tar.gz"
      sha256 "257d2079436bffaf95105ec4cac32226be6a9fffdb6460a2c3f8a3d00d8300c8"
    end
  end

  on_linux do
    url "https://github.com/lostintangent/oshen/releases/latest/download/oshen-linux-x86_64.tar.gz"
    sha256 "aafce6bb4445bc456dc1ab863fd55be83b381299fd89e7781474c13d7ebaa93f"
  end

  def install
    bin.install "oshen"
  end

  test do
    assert_equal "hello", shell_output("#{bin}/oshen -c 'echo hello'").strip
  end
end
