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
                Text("点「开始录制」后先把光标归位到左下角作为统一物理起点（约 1.5 秒），再回触控区或全键盘正常操作；所有指针移动、滚轮、按键、点击按真实时序记录。回放前同样归位，因此每次播放的轨迹落点一致。左下角起点也避开了 iPad 左上角双击锁屏的热区。")
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
                Text("左滑可删除。编辑页可修改每个动作的时间间隔、替换按键、删除动作。")
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

struct MacroEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Macro
    @State private var showKeyPicker = false
    @State private var replaceIndex = 0
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
                    EventEditorRow(event: $draft.events[idx], onReplaceKey: {
                        replaceIndex = idx
                        showKeyPicker = true
                    })
                }
                .onDelete { indexSet in
                    draft.events.remove(atOffsets: indexSet)
                }
                if draft.events.isEmpty {
                    Text("没有任何动作，可左滑删除这条宏重新录制。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("动作（\(draft.events.count)）")
            } footer: {
                Text("「间隔」是该动作距录制起点的秒数，改大即延后发生。按键行点「替换键位」可改成任意键。整体时序以每个动作的时间为准。")
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
        .sheet(isPresented: $showKeyPicker) {
            KeyPickerView(event: draft.events[replaceIndex]) { picked in
                if replaceIndex < draft.events.count {
                    draft.events[replaceIndex] = picked
                }
                showKeyPicker = false
            }
        }
    }
}

// MARK: - 单个动作编辑行

private struct EventEditorRow: View {
    @Binding var event: MacroEvent
    let onReplaceKey: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(String(format: "%.2f s", event.t))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 62, alignment: .leading)
                Text(event.summary)
                    .font(.subheadline)
                Spacer()
                if event.kind == .key {
                    Button("替换键位") { onReplaceKey() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                }
            }
            // 用滑杆微调该动作的发生时刻（0–30 秒，精度 0.01 秒），补足 TextField
            // 在小屏上不好输入小数的问题。
            Slider(value: Binding(
                get: { min(max(event.t, 0), 30) },
                set: { event.t = $0 }
            ), in: 0...30, step: 0.01)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 键位选择器

private struct KeyPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let event: MacroEvent
    let onPick: (MacroEvent) -> Void

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
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(Self.commonKeys, id: \.self) { label in
                        Button {
                            var e = event
                            if let resolved = HIDKeycode.resolve(label) {
                                e.keycode = resolved.keycode
                                e.modifiers = resolved.modifier
                                e.label = label
                            }
                            onPick(e)
                            dismiss()
                        } label: {
                            Text(label)
                                .font(.caption)
                                .frame(maxWidth: .infinity, minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()
            }
            .navigationTitle("替换键位")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("取消") { dismiss() }
                }
            }
        }
    }
}
