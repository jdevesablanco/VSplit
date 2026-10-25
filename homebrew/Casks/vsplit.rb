cask "vsplit" do
  version "1.0.0"
  sha256 "6395eb5eaaf27ef77cb28c5768541d806d0467ef913211e3f784677cebe785d5"

  url "https://github.com/jdevesablanco/VSplit/releases/download/v#{version}/VSplit-#{version}.dmg"
  name "VSplit"
  desc "Split a MIDI clip into natural voices and drag each one back into Logic Pro"
  homepage "https://github.com/jdevesablanco/VSplit"

  depends_on macos: :sonoma

  app "VSplit.app"
  binary "#{appdir}/VSplit.app/Contents/Resources/vsplit"

  # La app no está notarizada (no hay cuenta de Apple Developer de pago): sin esto macOS la bloquearía al abrirla.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/VSplit.app"], must_succeed: false
  end

  uninstall quit:      "io.github.jdevesablanco.VSplit",
            launchctl: "io.github.jdevesablanco.VSplit.watch",
            delete:    "~/Library/LaunchAgents/io.github.jdevesablanco.VSplit.watch.plist"
  zap trash: [
    "~/Library/Application Support/VSplit",
    "~/Library/Caches/VSplit",
    "~/Library/Preferences/io.github.jdevesablanco.VSplit.plist",
  ]
end
