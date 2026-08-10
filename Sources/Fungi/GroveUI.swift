import Cocoa
import UniformTypeIdentifiers

// MARK: - New tab UI: Grove, Post, Almanac, Hollow, Echo

extension PopoverViewController {

    private func makePane(in parent: NSView) -> NSView {
        let pane = NSView(frame: NSRect(x: 14, y: 16, width: 368, height: 408))
        parent.addSubview(pane)
        return pane
    }

    private func sectionLabel(_ text: String, y: CGFloat, in pane: NSView,
                              color: NSColor = FungiTheme.ink, font: NSFont = FungiTheme.subtitle) -> NSTextField {
        let l = SectionLabel(text, font: font, color: color)
        l.frame = NSRect(x: 0, y: y, width: 368, height: 18)
        pane.addSubview(l)
        return l
    }

    private func makeLogView(y: CGFloat, height: CGFloat, in pane: NSView) -> (NSScrollView, NSTextView) {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: y, width: 368, height: height))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 10
        let tv = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        tv.isEditable = false
        tv.font = FungiTheme.mono
        tv.textColor = FungiTheme.gill
        tv.backgroundColor = FungiTheme.canopy.withAlphaComponent(0.7)
        tv.autoresizingMask = [.width]
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 8, height: 8)
        scroll.documentView = tv
        pane.addSubview(scroll)
        return (scroll, tv)
    }

    // MARK: 🌳 Grove — snapping, HUDs, audio output, meetings, tools

    func buildGrove(in parent: NSView) {
        let pane = makePane(in: parent)
        grovePane = pane

        _ = sectionLabel("🪜 Trellis — window snapping", y: 388, in: pane)
        let snaps: [(String, CGFloat)] = [("⬅ Left", 74), ("➡ Right", 78), ("⛶ Full", 68), ("◰", 32), ("◳", 32), ("◱", 32), ("◲", 32)]
        var x: CGFloat = 0
        for (tag, (title, width)) in snaps.enumerated() {
            let b = ShroomButton(title: title, color: FungiTheme.gill)
            b.tag = tag
            b.target = self; b.action = #selector(snapWindow(_:))
            b.frame = NSRect(x: x, y: 356, width: width, height: 26)
            x += width + 5
            pane.addSubview(b)
        }

        _ = sectionLabel("🌟 Glow — volume · brightness · mic", y: 326, in: pane)
        let volIcon = sectionLabel("🔊", y: 296, in: pane)
        volIcon.frame = NSRect(x: 0, y: 296, width: 26, height: 18)
        groveVolume = NSSlider(value: 50, minValue: 0, maxValue: 100, target: self, action: #selector(volumeChanged(_:)))
        groveVolume.isContinuous = false
        groveVolume.frame = NSRect(x: 28, y: 294, width: 186, height: 22)
        pane.addSubview(groveVolume)
        let bDown = ShroomButton(title: "🔅", color: FungiTheme.gill)
        bDown.target = self; bDown.action = #selector(brightnessDown)
        bDown.frame = NSRect(x: 222, y: 292, width: 40, height: 26)
        pane.addSubview(bDown)
        let bUp = ShroomButton(title: "🔆", color: FungiTheme.gill)
        bUp.target = self; bUp.action = #selector(brightnessUp)
        bUp.frame = NSRect(x: 268, y: 292, width: 40, height: 26)
        pane.addSubview(bUp)
        groveMicBtn = ShroomButton(title: "🎙", color: FungiTheme.cap)
        groveMicBtn.target = self; groveMicBtn.action = #selector(toggleMicMute)
        groveMicBtn.frame = NSRect(x: 314, y: 292, width: 50, height: 26)
        pane.addSubview(groveMicBtn)

        _ = sectionLabel("🍃 Breeze — audio output (incl. AirPlay devices)", y: 262, in: pane)
        groveOutputs = NSPopUpButton(frame: NSRect(x: 0, y: 230, width: 300, height: 26), pullsDown: false)
        groveOutputs.target = self; groveOutputs.action = #selector(outputPicked(_:))
        pane.addSubview(groveOutputs)
        let refresh = ShroomButton(title: "↻", color: FungiTheme.gill)
        refresh.target = self; refresh.action = #selector(refreshOutputs)
        refresh.frame = NSRect(x: 308, y: 230, width: 40, height: 26)
        pane.addSubview(refresh)

        groveMeetingLabel = sectionLabel("🫂 Council: no meeting app detected", y: 200, in: pane,
                                         color: FungiTheme.fog, font: FungiTheme.body)

        _ = sectionLabel("🧰 Tools", y: 168, in: pane)
        let tools: [(String, Selector, CGFloat)] = [
            ("📸 Spore Print", #selector(captureSporePrint), 122),
            ("🌟 Firefly", #selector(openFirefly), 100),
            ("🫥 Peel", #selector(peelImage), 88)
        ]
        var tx: CGFloat = 0
        for (title, action, width) in tools {
            let b = ShroomButton(title: title, color: FungiTheme.spore)
            b.target = self; b.action = action
            b.frame = NSRect(x: tx, y: 132, width: width, height: 30)
            tx += width + 8
            pane.addSubview(b)
        }

        grovePowerToggle = NSButton(checkboxWithTitle: "🪫 Low Power Mode (asks for admin password)",
                                    target: self, action: #selector(toggleLowPower))
        grovePowerToggle.font = FungiTheme.body
        grovePowerToggle.frame = NSRect(x: 0, y: 100, width: 368, height: 20)
        pane.addSubview(grovePowerToggle)

        groveHint = NSTextField(labelWithString: "")
        groveHint.font = FungiTheme.mono
        groveHint.textColor = FungiTheme.whisper
        groveHint.maximumNumberOfLines = 0
        groveHint.lineBreakMode = .byWordWrapping
        groveHint.frame = NSRect(x: 0, y: 16, width: 368, height: 72)
        pane.addSubview(groveHint)

        SporePrint.shared.onSaved = { [weak self] url in
            self?.footerLabel.stringValue = "Spore print saved: \(url.lastPathComponent)"
            self?.fileTable.reloadData()
        }

        // Keep the picker honest when AirPods/AirPlay targets come and go.
        breezeObservers = Breeze.observeChanges { [weak self] in
            guard let self, self.currentTab == .grove else { return }
            self.reloadOutputs()
        }
    }

    func refreshGrove() {
        groveVolume.integerValue = Dew.outputVolume()
        reloadOutputs()
        if let meeting = Council.activeMeetingApp() {
            groveMeetingLabel.stringValue = "🫂 Council: \(meeting) is running — 🎙 mutes your mic system-wide"
            groveMeetingLabel.textColor = FungiTheme.moss
        } else {
            groveMeetingLabel.stringValue = "🫂 Council: no meeting app detected"
            groveMeetingLabel.textColor = FungiTheme.fog
        }
        groveMicBtn.title = Council.micVolume() == 0 ? "🔇" : "🎙"
        grovePowerToggle.state = LowPower.isOn() ? .on : .off
        groveHint.stringValue = Trellis.trusted
            ? "Trellis ready. Spore Print opens a markup editor after capture. Peel cuts out the subject of any image (macOS 14+)."
            : "Trellis needs Accessibility permission — click a snap button once to get the system prompt, then grant it in System Settings › Privacy & Security › Accessibility."
    }

    func reloadOutputs() {
        let devices = Breeze.outputDevices()
        groveOutputs.removeAllItems()
        for d in devices {
            groveOutputs.menu?.addItem(NSMenuItem(title: d.name, action: nil, keyEquivalent: ""))
        }
        if let def = Breeze.defaultOutput(), let idx = devices.firstIndex(of: def) {
            groveOutputs.selectItem(at: idx)
        }
    }

    @objc func snapWindow(_ sender: NSButton) {
        let positions: [SnapPosition] = [.left, .right, .full, .topLeft, .topRight, .bottomLeft, .bottomRight]
        guard sender.tag < positions.count else { return }
        if Trellis.snap(positions[sender.tag]) {
            footerLabel.stringValue = "Trellis: window snapped"
        } else {
            footerLabel.stringValue = "Trellis: grant Accessibility permission, then try again"
        }
    }

    @objc func volumeChanged(_ sender: NSSlider) {
        Dew.setOutput(sender.integerValue)
        footerLabel.stringValue = "Glow: volume \(sender.integerValue)%"
    }
    @objc func brightnessUp() { Sunbeam.up() }
    @objc func brightnessDown() { Sunbeam.down() }

    @objc func toggleMicMute() {
        let muted = Council.toggleMute()
        groveMicBtn.title = muted ? "🔇" : "🎙"
        footerLabel.stringValue = muted ? "Council: mic muted" : "Council: mic live"
    }

    @objc func outputPicked(_ sender: NSPopUpButton) {
        let idx = sender.indexOfSelectedItem
        guard idx >= 0, idx < Breeze.lastList.count else { return }
        let dev = Breeze.lastList[idx]
        if Breeze.setDefaultOutput(dev) {
            footerLabel.stringValue = "Breeze: output → \(dev.name)"
        } else {
            footerLabel.stringValue = "Breeze: couldn't switch to \(dev.name)"
        }
    }
    @objc func refreshOutputs() { reloadOutputs() }

    @objc func captureSporePrint() {
        footerLabel.stringValue = "Spore Print: drag to capture a region…"
        SporePrint.shared.capture()
    }
    @objc func openFirefly() { Firefly.shared.toggle() }

    @objc func peelImage() {
        let pick = NSOpenPanel()
        pick.canChooseFiles = true
        pick.allowsMultipleSelection = false
        pick.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        pick.message = "Pick an image — Peel cuts out the subject and drops it in the Basket"
        guard pick.runModal() == .OK, let url = pick.url else { return }
        footerLabel.stringValue = "Peeling \(url.lastPathComponent)…"
        Peel.removeBackground(from: url) { [weak self] dest, msg in
            self?.footerLabel.stringValue = msg
            if dest != nil { self?.fileTable.reloadData() }
        }
    }

    @objc func toggleLowPower() {
        let on = grovePowerToggle.state == .on
        footerLabel.stringValue = "Asking for admin rights to turn Low Power Mode \(on ? "on" : "off")…"
        LowPower.set(on) { [weak self] ok in
            guard let self else { return }
            self.grovePowerToggle.state = LowPower.isOn() ? .on : .off
            self.footerLabel.stringValue = ok ? "🪫 Low Power Mode \(on ? "on" : "off")" : "Low Power Mode unchanged (cancelled or failed)"
        }
    }

    // MARK: 📮 Post — instant replies

    func buildPost(in parent: NSView) {
        let pane = makePane(in: parent)
        postPane = pane

        _ = sectionLabel("📮 Quick replies without opening the app", y: 388, in: pane)

        postHandleField = NSTextField(string: "")
        postHandleField.placeholderString = "iMessage handle or phone (+15551234567)"
        postHandleField.bezelStyle = .roundedBezel
        postHandleField.font = FungiTheme.body
        postHandleField.frame = NSRect(x: 0, y: 350, width: 368, height: 28)
        pane.addSubview(postHandleField)

        postMessageField = NSTextField(string: "")
        postMessageField.placeholderString = "Your message…"
        postMessageField.bezelStyle = .roundedBezel
        postMessageField.font = FungiTheme.body
        postMessageField.frame = NSRect(x: 0, y: 312, width: 368, height: 30)
        pane.addSubview(postMessageField)

        let sendIM = ShroomButton(title: "📨 Send iMessage", color: FungiTheme.moss)
        sendIM.target = self; sendIM.action = #selector(postIMessage)
        sendIM.frame = NSRect(x: 0, y: 268, width: 160, height: 32)
        pane.addSubview(sendIM)

        let sendWA = ShroomButton(title: "💬 WhatsApp draft", color: FungiTheme.spore)
        sendWA.target = self; sendWA.action = #selector(postWhatsApp)
        sendWA.frame = NSRect(x: 170, y: 268, width: 160, height: 32)
        pane.addSubview(sendWA)

        postStatus = NSTextField(labelWithString: "")
        postStatus.font = FungiTheme.body
        postStatus.textColor = FungiTheme.moss
        postStatus.maximumNumberOfLines = 2
        postStatus.lineBreakMode = .byWordWrapping
        postStatus.frame = NSRect(x: 0, y: 220, width: 368, height: 40)
        pane.addSubview(postStatus)

        let hint = NSTextField(labelWithString: "📨 iMessage sends instantly through the Messages app — the first send asks for an Automation permission.\n\n💬 WhatsApp opens the app (or wa.me) with the number and text pre-filled — press return there to send.")
        hint.font = FungiTheme.body
        hint.textColor = FungiTheme.fog
        hint.maximumNumberOfLines = 0
        hint.lineBreakMode = .byWordWrapping
        hint.frame = NSRect(x: 0, y: 60, width: 368, height: 140)
        pane.addSubview(hint)
    }

    @objc func postIMessage() {
        let handle = postHandleField.stringValue.trimmingCharacters(in: .whitespaces)
        let msg = postMessageField.stringValue
        guard !handle.isEmpty, !msg.isEmpty else {
            postStatus.stringValue = "Need both a handle and a message"
            return
        }
        postStatus.stringValue = "Sending…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let (ok, err) = QuickPost.sendIMessage(to: handle, text: msg)
            DispatchQueue.main.async {
                guard let self else { return }
                if ok {
                    self.postStatus.stringValue = "📨 Sent via iMessage"
                    self.postMessageField.stringValue = ""
                } else {
                    self.postStatus.stringValue = "iMessage failed: \(err)"
                }
            }
        }
    }

    @objc func postWhatsApp() {
        let handle = postHandleField.stringValue.trimmingCharacters(in: .whitespaces)
        let msg = postMessageField.stringValue
        guard !handle.isEmpty else { postStatus.stringValue = "Need a phone number for WhatsApp"; return }
        QuickPost.openWhatsApp(phone: handle, text: msg)
        postStatus.stringValue = "💬 Opened WhatsApp with your draft"
    }

    // MARK: 📖 Almanac — natural-language events & reminders

    func buildAlmanac(in parent: NSView) {
        let pane = makePane(in: parent)
        almanacPane = pane

        _ = sectionLabel("📖 Say it in plain words", y: 388, in: pane)

        almanacField = NSTextField(string: "")
        almanacField.placeholderString = "Lunch with Sam tomorrow 12:30"
        almanacField.bezelStyle = .roundedBezel
        almanacField.font = FungiTheme.body
        almanacField.frame = NSRect(x: 0, y: 348, width: 368, height: 30)
        almanacField.target = self
        almanacField.action = #selector(almanacAdd)
        pane.addSubview(almanacField)

        almanacReminderToggle = NSButton(checkboxWithTitle: "Create as reminder instead of calendar event",
                                         target: nil, action: nil)
        almanacReminderToggle.font = FungiTheme.body
        almanacReminderToggle.frame = NSRect(x: 0, y: 316, width: 368, height: 20)
        pane.addSubview(almanacReminderToggle)

        let add = ShroomButton(title: "🌱 Plant it", color: FungiTheme.moss)
        add.target = self; add.action = #selector(almanacAdd)
        add.frame = NSRect(x: 0, y: 274, width: 130, height: 32)
        pane.addSubview(add)

        almanacStatus = NSTextField(labelWithString: "")
        almanacStatus.font = FungiTheme.body
        almanacStatus.textColor = FungiTheme.moss
        almanacStatus.maximumNumberOfLines = 3
        almanacStatus.lineBreakMode = .byWordWrapping
        almanacStatus.frame = NSRect(x: 0, y: 210, width: 368, height: 56)
        pane.addSubview(almanacStatus)

        let hint = NSTextField(labelWithString: "The date is parsed from your words; the rest becomes the title.\n\nTry:\n·  Standup Friday 9am\n·  Water the mushrooms tonight at 8\n·  Dentist June 3 14:00\n\nEvents default to one hour. Reminders get an alarm at the parsed time.")
        hint.font = FungiTheme.body
        hint.textColor = FungiTheme.fog
        hint.maximumNumberOfLines = 0
        hint.lineBreakMode = .byWordWrapping
        hint.frame = NSRect(x: 0, y: 30, width: 368, height: 164)
        pane.addSubview(hint)
    }

    @objc func almanacAdd() {
        let input = almanacField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !input.isEmpty else { return }
        almanacStatus.stringValue = "Planting…"
        Almanac.plant(input, asReminder: almanacReminderToggle.state == .on) { [weak self] msg in
            self?.almanacStatus.stringValue = msg
            self?.footerLabel.stringValue = msg
            if msg.hasPrefix("🌱") { self?.almanacField.stringValue = "" }
        }
    }

    // MARK: 🪵 Hollow — terminal

    func buildHollow(in parent: NSView) {
        let pane = makePane(in: parent)
        hollowPane = pane

        hollowField = NSTextField(string: "")
        hollowField.placeholderString = "echo hello from the hollow"
        hollowField.bezelStyle = .roundedBezel
        hollowField.font = FungiTheme.mono
        hollowField.frame = NSRect(x: 0, y: 374, width: 296, height: 28)
        hollowField.target = self
        hollowField.action = #selector(hollowRun)
        pane.addSubview(hollowField)

        let run = ShroomButton(title: "Run ⏎", color: FungiTheme.cap)
        run.target = self; run.action = #selector(hollowRun)
        run.frame = NSRect(x: 304, y: 372, width: 64, height: 30)
        pane.addSubview(run)

        let (_, tv) = makeLogView(y: 16, height: 348, in: pane)
        hollowOutput = tv
        appendHollow("🪵 zsh in the hollow log. Commands run with your login shell.\n")
    }

    func appendHollow(_ s: String) {
        hollowOutput.textStorage?.append(NSAttributedString(string: s, attributes: [
            .font: FungiTheme.mono, .foregroundColor: FungiTheme.gill
        ]))
        hollowOutput.scrollToEndOfDocument(nil)
    }

    @objc func hollowRun() {
        let cmd = hollowField.stringValue.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return }
        hollowField.stringValue = ""
        appendHollow("\n$ \(cmd)\n")
        Hollow.shared.run(cmd) { [weak self] out in
            self?.appendHollow(out + "\n")
        }
    }

    // MARK: 🎙 Echo — voice recording + transcription

    func buildEcho(in parent: NSView) {
        let pane = makePane(in: parent)
        echoPane = pane

        echoButton = ShroomButton(title: "⏺  Record", color: FungiTheme.cap)
        echoButton.target = self; echoButton.action = #selector(echoToggle)
        echoButton.frame = NSRect(x: 0, y: 372, width: 120, height: 32)
        pane.addSubview(echoButton)

        echoStatus = NSTextField(labelWithString: "Recordings + transcripts land in Echoes/ (iCloud)")
        echoStatus.font = FungiTheme.body
        echoStatus.textColor = FungiTheme.fog
        echoStatus.lineBreakMode = .byTruncatingTail
        echoStatus.frame = NSRect(x: 130, y: 378, width: 238, height: 20)
        pane.addSubview(echoStatus)

        let (_, tv) = makeLogView(y: 16, height: 344, in: pane)
        echoOutput = tv

        EchoRecorder.shared.onTranscript = { [weak self] text in
            guard let self else { return }
            let df = DateFormatter(); df.dateFormat = "HH:mm"
            self.echoOutput.textStorage?.append(NSAttributedString(
                string: "🎙 \(df.string(from: Date()))\n\(text)\n\n",
                attributes: [.font: FungiTheme.mono, .foregroundColor: FungiTheme.gill]))
            self.echoOutput.scrollToEndOfDocument(nil)
            self.echoStatus.stringValue = "Transcript saved next to the recording"
        }
    }

    @objc func echoToggle() {
        if EchoRecorder.shared.isRecording {
            EchoRecorder.shared.stop()
            echoButton.title = "⏺  Record"
            echoStatus.stringValue = "Transcribing…"
        } else {
            EchoRecorder.shared.begin { [weak self] msg, started in
                guard let self else { return }
                self.echoStatus.stringValue = msg
                if started { self.echoButton.title = "⏹  Stop" }
            }
        }
    }

    // MARK: 🐦 Songbird toggle (lives on the Media tab)

    @objc func toggleLyrics() {
        if lyricsToggle.state == .on {
            Songbird.shared.onUpdate = { [weak self] s in self?.lyricsLabel.stringValue = s }
            Songbird.shared.start()
            lyricsLabel.stringValue = "🐦 Listening for the Music app…"
        } else {
            Songbird.shared.stop()
            lyricsLabel.stringValue = ""
        }
    }
}
