import SwiftUI

// MARK: - 宏管理主页（录制 / 列表 / 播放控制）

struct MacroListView: View {
    @EnvironmentObject private var hid: HIDPeripheral
    @EnvironmentObject private var store: MacroStore

    @State private var showSaveAlert = false
    @State private var newMacroName = ""
    @State private var editingMacro: Macro?
    @State private var playMode: PlayMode = .once
    @State private var playCount: Int = 3

    var body: some View {
        Form {
            // 录制控制
            Section {
                if hid.isRecording {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 10, height: 10)
                        Text("正在录制…")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                    }
                    Button(role: .destructive) {
                        // 用默认名直接落库，稍后可在列表里重命名。
                        let d = DateFormatter()
                        d.dateFormat = "HHmmss"
                        newMacroName = "宏 \(d.string(from: Date()))"
                        showSaveAlert = true
                    } label: {
                        Label("停止并保存", systemImage: "stop.circle.fill")
                    }
                } else {
                    Button {
                        hid.startRecording()
                    } label: {
                        Label("开始录制", systemImage: "record.circle")
                    }
                    .disabled(hid.isHoming || hid.isPlaying)
                }
                if hid.isHoming {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("正在归位光标到左下角起点…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("点「开始录制」后先把光标归位到左下角作为统一物理起点（约 1.5 秒），再回触控区或全键盘正常操作；所有指针移动、滚轮、按键、点击按真实时序记录。回放前同样归位，因此每次播放的轨迹落点一致。起点已设在左下角，不会触发屏幕角落的双击锁屏手势。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("录制")
            }

            // 播放控制
            Section {
                Picker("播放模式", selection: $playMode) {
                    Text("单次").tag(PlayMode.once)
                    Text("指定次数").tag(PlayMode.times(0))
                    Text("无限循环").tag(PlayMode.infinite)
                }
                .pickerStyle(.segmented)
                if case .times = playMode {
                    Stepper(value: $playCount, in: 1...99) {
                        Text("播放 \(playCount) 次后停止")
                    }
                }
                if hid.isPlaying {
                    HStack {
                        Image(systemName: "play.circle.fill")
                            .foregroundStyle(.green)
                        Text("正在回放：\(hid.playingMacroName)")
                            .font(.subheadline)
                        Spacer()
                        Text(hid.playbackRemaining < 0 ? "∞" : "剩 \(hid.playbackRemaining) 次")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { hid.stopPlayback() } label: {
                        Label("停止回放", systemImage: "stop.circle")
                    }
                }
            } header: {
                Text("播放")
            } footer: {
                Text("每次播放（含循环的每一轮）都会先把光标归位到左下角，再按录制时序回放，所以轨迹落点每次一致。「指定次数」用 Stepper 设定 1–99 次；无限循环需手动停止。")
                    .font(.caption)
            }

            // 宏列表
            Section {
                if store.macros.isEmpty {
                    Text("还没有保存的宏。先点上面「开始录制」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.macros) { macro in
                        MacroRow(macro: macro,
                                 playDisabled: hid.isHoming || hid.isRecording,
                                 onPlay: { play(macro) },
                                 onEdit: { editingMacro = macro })
                    }
                    .onDelete { indexSet in
                        for i in indexSet { store.delete(id: store.macros[i].id) }
                    }
                }
            } header: {
                Text("已保存的宏（\(store.macros.count)）")
            } footer: {
                Text("左滑可删除。编辑页可改每个动作的类型、时间、坐标 / 按键 / 点击参数，也能在中间插入新动作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("键鼠宏")
        .navigationBarTitleDisplayMode(.inline)
        .alert("保存录制", isPresented: $showSaveAlert) {
            TextField("宏名称", text: $newMacroName)
            Button("取消", role: .cancel) {
                // 取消保存：丢弃这次录制，不落库。
                _ = hid.stopRecording(name: "")
            }
            Button("保存") {
                let name = newMacroName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty,
                      let macro = hid.stopRecording(name: name) else { return }
                store.add(macro)
            }
        } message: {
            Text("给这段录制起个名字，方便以后区分。")
        }
        .sheet(item: $editingMacro) { macro in
            NavigationStack {
                MacroEditorView(macro: macro) { updated in
                    store.update(updated)
                    if hid.isPlaying && hid.playingMacroName == updated.name {
                        hid.replacePlayingEvents(updated.events)
                    }
                }
            }
        }
    }

    private func play(_ macro: Macro) {
        let mode: PlayMode
        switch playMode {
        case .times: mode = .times(playCount)
        default: mode = playMode
        }
        hid.play(macro: macro, mode: mode)
    }
}

// MARK: - 宏列表单行

private struct MacroRow: View {
    let macro: Macro
    var playDisabled: Bool = false
    let onPlay: () -> Void
    let onEdit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(macro.name)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(String(format: "%.1f 秒", macro.duration))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Text("\(macro.events.count) 个动作")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { onPlay() } label: {
                    Label("播放", systemImage: "play.fill")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(playDisabled)
                Button { onEdit() } label: {
                    Label("编辑", systemImage: "square.and.pencil")
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 宏编辑器

/// 供 .sheet(item:) 使用的编辑目标（动作下标）。
private struct EventEditTarget: Identifiable {
    let index: Int
    var id: Int { index }
}

struct MacroEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Macro
    /// 正在编辑的动作；nil = 没有打开动作编辑页。
    @State private var editTarget: EventEditTarget?
    let onSave: (Macro) -> Void

    init(macro: Macro, onSave: @escaping (Macro) -> Void) {
        _draft = State(initialValue: macro)
        self.onSave = onSave
    }

    var body: some View {
        Form {
            Section {
                TextField("宏名称", text: $draft.name)
            } header: {
                Text("名称")
            }

            Section {
                ForEach(Array(draft.events.indices), id: \.self) { idx in
                    EventEditorRow(
                        event: $draft.events[idx],
                        index: idx,
                        cumulative: cumulativePosition(upTo: idx),
                        onEdit: { editTarget = EventEditTarget(index: idx) },
                        onInsertAfter: { insertEvent(after: idx) },
                        onDelete: { draft.events.remove(at: idx) }
                    )
                }
                Button {
                    insertEvent(after: nil)
                } label: {
                    Label("在末尾添加动作", systemImage: "plus.circle")
                }
                .font(.subheadline)
            } header: {
                Text("动作（\(draft.events.count)）")
            } footer: {
                Text("点任一动作可改类型、时间、坐标 / 按键 / 点击参数；点「插」在它后面插入新动作，或左滑删除。坐标以录制起点（左下角）为原点，X 向右为正、Y 向下为正。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $draft.duration, in: 0...3600, step: 0.1) {
                    Text("总时长 \(String(format: "%.1f", draft.duration)) 秒")
                }
                Text("总时长决定一轮回放结束后多久开始下一轮；实际以最后一个动作的时间为准。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("时长")
            }
        }
        .navigationTitle("编辑宏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("取消") { dismiss() }
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("保存") {
                    onSave(draft)
                    dismiss()
                }
                .fontWeight(.semibold)
            }
        }
        .sheet(item: $editTarget) { target in
            if target.index < draft.events.count {
                EventEditorView(
                    event: draft.events[target.index],
                    positionBefore: target.index > 0
                        ? cumulativePosition(upTo: target.index - 1) : (x: 0, y: 0),
                    index: target.index,
                    onCommit: { edited in
                        if target.index < draft.events.count {
                            draft.events[target.index] = edited
                        }
                        editTarget = nil
                    }
                )
            }
        }
    }

    /// 到第 idx 个动作为止的累计指针位置（只累计 move 的 dx/dy）。
    private func cumulativePosition(upTo idx: Int) -> (x: Int, y: Int) {
        var x = 0, y = 0
        guard idx >= 0, !draft.events.isEmpty else { return (x, y) }
        for i in 0...min(idx, draft.events.count - 1) where draft.events[i].kind == .move {
            x += draft.events[i].dx
            y += draft.events[i].dy
        }
        return (x, y)
    }

    /// 在指定动作之后插入一条新动作（默认「左键单击」，随后立刻打开编辑页改类型/参数）。
    private func insertEvent(after idx: Int?) {
        let at: Int
        if let idx = idx { at = min(idx + 1, draft.events.count) }
        else { at = draft.events.count }
        let prevT = at > 0 ? draft.events[at - 1].t : 0
        let nextT = at < draft.events.count ? draft.events[at].t : prevT + 0.5
        let newT = nextT > prevT ? prevT + min(0.25, (nextT - prevT) / 2) : prevT + 0.25
        draft.events.insert(MacroEvent(kind: .click, t: newT, mask: 0x01), at: at)
        editTarget = EventEditTarget(index: at)
    }
}

// MARK: - 单个动作编辑行

private struct EventEditorRow: View {
    @Binding var event: MacroEvent
    let index: Int
    let cumulative: (x: Int, y: Int)
    let onEdit: () -> Void
    let onInsertAfter: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(String(format: "%.2f", event.t))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .leading)
                Text("#\(index + 1)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(event.summary)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button("改") { onEdit() }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                Button("插") { onInsertAfter() }
                    .font(.caption2)
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            }
            if event.kind == .move {
                Text("到达坐标 X \(cumulative.x) · Y \(cumulative.y)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { onDelete() } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

// MARK: - 动作编辑页（类型 / 时间 / 坐标 / 按键 / 点击）

private struct EventEditorView: View {
    @Environment(\.dismiss) private var dismiss
    /// 编辑本地副本，点「完成」才回写；点「取消」丢弃本次改动。
    @State private var event: MacroEvent
    let positionBefore: (x: Int, y: Int)
    let index: Int
    let onCommit: (MacroEvent) -> Void

    init(event: MacroEvent,
         positionBefore: (x: Int, y: Int),
         index: Int,
         onCommit: @escaping (MacroEvent) -> Void) {
        _event = State(initialValue: event)
        self.positionBefore = positionBefore
        self.index = index
        self.onCommit = onCommit
    }

    @State private var absoluteX = ""
    @State private var absoluteY = ""

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .none
        f.allowsFloats = false
        return f
    }()
    private static let doubleFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 2
        return f
    }()

    var body: some View {
        NavigationStack {
            Form {
                Section("操作类型") {
                    Picker("类型", selection: $event.kind) {
                        Text("移动指针").tag(MacroEvent.Kind.move)
                        Text("滚轮").tag(MacroEvent.Kind.wheel)
                        Text("按键").tag(MacroEvent.Kind.key)
                        Text("鼠标按下").tag(MacroEvent.Kind.buttonDown)
                        Text("鼠标抬起").tag(MacroEvent.Kind.buttonUp)
                        Text("点击").tag(MacroEvent.Kind.click)
                    }
                    .pickerStyle(.menu)
                }

                Section("发生时间") {
                    HStack {
                        Text("距录制起点")
                        Spacer()
                        TextField("秒", value: $event.t, formatter: Self.doubleFormatter)
                            .keyboardType(.numbersAndPunctuation)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                        Text("秒")
                    }
                    Slider(value: $event.t, in: 0...60, step: 0.01)
                }

                switch event.kind {
                case .move:
                    Section("指针位移（本帧相对位移）") {
                        Stepper("水平 dx：\(event.dx)", value: $event.dx, in: -2000...2000, step: 1)
                        Stepper("垂直 dy：\(event.dy)", value: $event.dy, in: -2000...2000, step: 1)
                        HStack(spacing: 8) {
                            Text("dx")
                            TextField("0", value: $event.dx, formatter: Self.intFormatter)
                                .keyboardType(.numbersAndPunctuation)
                                .textFieldStyle(.roundedBorder)
                            Text("dy")
                            TextField("0", value: $event.dy, formatter: Self.intFormatter)
                                .keyboardType(.numbersAndPunctuation)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    Section("位置坐标（原点：录制起点左下角）") {
                        Text("本步执行后到达：X \(positionBefore.x + event.dx) · Y \(positionBefore.y + event.dy)")
                            .font(.subheadline)
                        HStack(spacing: 8) {
                            Text("设到 X")
                            TextField("X", text: $absoluteX)
                                .keyboardType(.numbersAndPunctuation)
                                .textFieldStyle(.roundedBorder)
                            Text("Y")
                            TextField("Y", text: $absoluteY)
                                .keyboardType(.numbersAndPunctuation)
                                .textFieldStyle(.roundedBorder)
                        }
                        Button("应用坐标") {
                            let tx = Int(absoluteX.trimmingCharacters(in: .whitespaces)) ?? positionBefore.x + event.dx
                            let ty = Int(absoluteY.trimmingCharacters(in: .whitespaces)) ?? positionBefore.y + event.dy
                            event.dx = tx - positionBefore.x
                            event.dy = ty - positionBefore.y
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        Text("HID 只能发相对位移，所以绝对坐标会换算成本步 dx/dy；改这一步会同时改变其后所有动作的实际落点。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .wheel:
                    Section("滚轮") {
                        Stepper("滚动量：\(event.wheel)", value: $event.wheel, in: -500...500, step: 1)
                        HStack {
                            Text("数值")
                            TextField("0", value: $event.wheel, formatter: Self.intFormatter)
                                .keyboardType(.numbersAndPunctuation)
                                .textFieldStyle(.roundedBorder)
                        }
                        Text("正数 = 滚轮上滑，负数 = 下滑（受自然滚动开关影响）。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                case .key:
                    Section("按键") {
                        let name = event.label.isEmpty ? String(format: "0x%02X", event.keycode) : event.label
                        Text("当前：\(MacroEvent.modifierText(event.modifiers).isEmpty ? "" : MacroEvent.modifierText(event.modifiers) + " + ")\(name)")
                            .font(.subheadline)
                        Toggle("Ctrl", isOn: modifierBinding(0x01))
                        Toggle("Shift", isOn: modifierBinding(0x02))
                        Toggle("Opt", isOn: modifierBinding(0x04))
                        Toggle("Cmd", isOn: modifierBinding(0x08))
                    }
                    Section("选择键位") {
                        KeyGridView { label in
                            if let resolved = HIDKeycode.resolve(label) {
                                event.keycode = resolved.keycode
                                event.modifiers = resolved.modifier
                                event.label = label
                            }
                        }
                    }
                case .buttonDown, .buttonUp:
                    Section("鼠标键") {
                        mouseMaskPicker
                    }
                case .click:
                    Section("点击") {
                        mouseMaskPicker
                        Stepper("连击次数：\(event.count)", value: $event.count, in: 1...10, step: 1)
                    }
                }
            }
            .navigationTitle("编辑动作 \(index + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                absoluteX = String(positionBefore.x + event.dx)
                absoluteY = String(positionBefore.y + event.dy)
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") {
                        onCommit(event)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private var mouseMaskPicker: some View {
        Picker("鼠标键", selection: $event.mask) {
            Text("左键").tag(UInt8(0x01))
            Text("右键").tag(UInt8(0x02))
            Text("中键").tag(UInt8(0x04))
        }
        .pickerStyle(.segmented)
    }

    private func modifierBinding(_ bit: UInt8) -> Binding<Bool> {
        Binding(
            get: { event.modifiers & bit != 0 },
            set: { on in
                if on { event.modifiers |= bit }
                else { event.modifiers &= ~bit }
            }
        )
    }
}

// MARK: - 键位网格（动作编辑页内直接选键）

private struct KeyGridView: View {
    let onPick: (String) -> Void

    /// 常用键：功能键来自 HIDKeycode.named，再加字母与数字。
    private static let commonKeys: [String] = {
        var names = Array(HIDKeycode.named.keys)
        names += ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
                  "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
                  "1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
        return names
    }()

    private let columns = [GridItem(.adaptive(minimum: 52), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(Self.commonKeys, id: \.self) { label in
                Button { onPick(label) } label: {
                    Text(label)
                        .font(.caption)
                        .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }
}
