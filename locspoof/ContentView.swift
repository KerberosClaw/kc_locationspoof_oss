import SwiftUI
import MapKit
import AppKit
import Combine

struct ContentView: View {
    @EnvironmentObject var status: StatusModel
    @StateObject private var search = SearchController()
    @StateObject private var walk = WalkController()
    @StateObject private var saved = SavedLocationsStore()
    @StateObject private var walkStepTrigger = WalkStepTrigger()

    @State private var locationQuery: String = ""
    @State private var latText: String = ""
    @State private var lonText: String = ""
    @State private var gmapURL: String = ""
    @State private var gmapBusy: Bool = false
    @State private var directInjectTab: DirectInjectTab = .search

    /// 畫圖 v2：是否在 active drawing 階段。
    @State private var isDrawing: Bool = false
    /// 畫圖 v2：當前累積的 strokes（lat/lon 為 source of truth、resize 也對得齊）。
    @State private var drawingStrokes: [[CLLocationCoordinate2D]] = []
    /// 畫圖 v2：MKMapView ref holder — 給 DrawingCanvasView 做螢幕點 ↔ 經緯度轉換。
    @StateObject private var mapRef = MapViewRef()

    /// Token-keyed center request — bumping the UUID forces MapClickView to
    /// re-apply setRegion even if the coordinate is unchanged.
    @State private var centerRequest: CenterRequest?

    /// Latest map region observed from MKMapView. Used to bias MKLocalSearch.
    @State private var currentRegion: MKCoordinateRegion = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 24.1477, longitude: 120.6736),
        span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
    )

    /// 加入收藏對話框暫存
    @State private var addSavedFor: Coordinate?
    @State private var addSavedName: String = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 280)
                .background(.regularMaterial)
            Divider()
            ZStack {
                MapClickView(
                    preview: status.previewCoord,
                    spoofed: status.snapshot.lastLoc,
                    waypoints: walk.queue.targets,
                    anchorWaypointId: squareAnchorId,
                    squareCorners: squareCornersForOverlay,
                    polylineCoords: freeDrawPolylineCoords,
                    isFreeDrawMode: walk.mode == .freeDraw,
                    centerRequest: centerRequest,
                    mapRef: mapRef,
                    onTap: handleMapTap,
                    onRegionChange: { region in currentRegion = region }
                )
                if isDrawing {
                    DrawingCanvasView(
                        strokes: $drawingStrokes,
                        mapRef: mapRef
                    )
                    .allowsHitTesting(true)
                }
            }
        }
        .onAppear {
            walk.attach(status: status)
            walkStepTrigger.attach(walk: walk, status: status)
        }
        .onChange(of: walk.mode) { _ in
            walk.clearQueue()
            // mode 切走 → 強制退出 active drawing
            if walk.mode != .freeDraw && isDrawing {
                isDrawing = false
                drawingStrokes.removeAll()
            }
        }
        .onChange(of: walk.queue.speedKmh) { _ in
            if walk.mode == .squareCruise && walk.queue.targets.count == 4 {
                walk.regenerateSquare()
            }
        }
        .sheet(item: $addSavedFor) { coord in
            addSavedSheet(coord: coord)
        }
    }

    private func addSavedSheet(coord: Coordinate) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("加入收藏").font(.headline)
            Text(String(format: "%.5f, %.5f", coord.lat, coord.lon))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("名稱（如：家、公司、中央公園）", text: $addSavedName)
                .textFieldStyle(.roundedBorder)
                .onSubmit { confirmAddSaved(coord: coord) }
            HStack {
                Spacer()
                Button("取消") {
                    addSavedFor = nil
                    addSavedName = ""
                }
                Button("加入") { confirmAddSaved(coord: coord) }
                    .keyboardShortcut(.return)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    private func confirmAddSaved(coord: Coordinate) {
        saved.add(name: addSavedName, coordinate: coord)
        addSavedFor = nil
        addSavedName = ""
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                statusSection
                Divider()
                directInjectSection
                Divider()
                savedSection
                Divider()
                modeSection
                if walk.mode == .squareCruise {
                    Divider()
                    squareSection
                }
                if walk.mode == .freeDraw {
                    Divider()
                    drawControlSection
                }
                Divider()
                walkSection
                    .disabled(walk.mode == .teleport)
                    .opacity(walk.mode == .teleport ? 0.4 : 1.0)
                Divider()
                emergencySection
            }
            .padding(14)
        }
    }

    // MARK: - Saved locations section

    private var savedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("收藏")
            HStack {
                Button {
                    addSavedFor = status.snapshot.lastLoc
                        ?? status.previewCoord
                        ?? Coordinate(
                            lat: currentRegion.center.latitude,
                            lon: currentRegion.center.longitude
                        )
                    addSavedName = ""
                } label: {
                    Label("加目前位置", systemImage: "star")
                }
                .controlSize(.small)
                Spacer()
            }
            if saved.items.isEmpty {
                Text("尚未收藏").font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(saved.items) { item in
                    HStack {
                        Button {
                            applySaved(item)
                        } label: {
                            HStack {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.name).font(.body)
                                    Text(String(format: "%.4f, %.4f",
                                                item.coordinate.lat, item.coordinate.lon))
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            saved.remove(id: item.id)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func applySaved(_ item: SavedLocation) {
        centerRequest = CenterRequest(
            id: UUID(),
            coordinate: CLLocationCoordinate2D(
                latitude: item.coordinate.lat,
                longitude: item.coordinate.lon
            )
        )
        switch walk.mode {
        case .teleport:
            Task { await status.inject(lat: item.coordinate.lat, lon: item.coordinate.lon) }
        case .walk:
            walk.addTarget(at: item.coordinate)
        case .squareCruise:
            walk.spawnSquare(at: item.coordinate)
            zoomFitSquare(anchor: item.coordinate)
            confirmInjectToAnchor(coord: item.coordinate)
        case .freeDraw:
            break  // 畫圖 mode 收藏點無動作（用畫布建 path）
        }
    }

    // MARK: - Status section

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("狀態")
            HStack {
                Image(systemName: status.iconSystemName)
                    .foregroundStyle(status.iconColor)
                Text(status.headline).font(.body)
            }
            if let coord = status.coordinateText {
                Text("注入中 \(coord)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.red)
            }
            if let p = status.previewCoord {
                Text(String(format: "預覽 %.4f, %.4f", p.lat, p.lon))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.blue)
            }
        }
    }

    // MARK: - Direct inject (tabbed)

    private var directInjectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("直接注入")
            Picker("", selection: $directInjectTab) {
                Text("搜尋地點").tag(DirectInjectTab.search)
                Text("經緯度").tag(DirectInjectTab.coord)
                Text("GMap").tag(DirectInjectTab.gmap)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch directInjectTab {
            case .search: searchSection
            case .coord:  coordSection
            case .gmap:   gmapSection
            }
        }
    }

    private var gmapSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("https://maps.app.goo.gl/... 或 google.com/maps URL", text: $gmapURL)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runGMapParse() }
            HStack {
                Button("解析並預覽") { runGMapParse() }
                    .disabled(gmapURL.trimmingCharacters(in: .whitespaces).isEmpty || gmapBusy)
                if gmapBusy {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            Text("支援 google.com/maps、maps.app.goo.gl、goo.gl/maps（短網址會自動解析重導）")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    // MARK: - Search section

    private var searchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("搜尋地點")
            TextField("台北車站 / 高雄 85 大樓", text: $locationQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { runLocationSearch() }
            HStack {
                Button("搜尋") { runLocationSearch() }
                    .disabled(locationQuery.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
            }
            if !search.results.isEmpty || search.lastQueryHadNoResults {
                searchResultsList
            }
        }
    }

    private var searchResultsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            if search.results.isEmpty {
                Text("無結果")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(6)
            } else {
                ForEach(Array(search.results.enumerated()), id: \.element.id) { idx, item in
                    Button {
                        selectSearchResult(item)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).font(.body)
                            Text(item.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if idx < search.results.count - 1 { Divider() }
                }
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }

    // MARK: - Coord direct input

    private var coordSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("經緯度直輸")
            HStack {
                Text("lat").font(.caption).foregroundStyle(.secondary).frame(width: 24)
                coordField(text: $latText, placeholder: "24.148", isValid: latValid)
            }
            HStack {
                Text("lon").font(.caption).foregroundStyle(.secondary).frame(width: 24)
                coordField(text: $lonText, placeholder: "120.673", isValid: lonValid)
            }
            Button("傳送此座標") { applyCoordInput() }
                .disabled(!coordsValid)
                .frame(maxWidth: .infinity)
        }
    }

    private func coordField(text: Binding<String>, placeholder: String, isValid: Bool) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.roundedBorder)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(text.wrappedValue.isEmpty || isValid ? .clear : .red, lineWidth: 1.5)
            )
    }

    // MARK: - Mode toggle

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("模式")
            Picker("", selection: $walk.mode) {
                Text("傳送").tag(MapMode.teleport)
                Text("走路").tag(MapMode.walk)
                Text("巡迴").tag(MapMode.squareCruise)
                Text("畫圖").tag(MapMode.freeDraw)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Text(modeCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var modeCaption: String {
        switch walk.mode {
        case .teleport:     return "點地圖任意位置 → 立即傳送"
        case .walk:         return "點地圖加點 → 按開始走"
        case .squareCruise: return "點地圖 A → 自動生 4 點環路、邊長依速度計算"
        case .freeDraw:     return "按 開始畫圖 + 上一步。畫完按 結束畫圖。"
        }
    }

    private var squareSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("方形巡迴")
            HStack {
                Text("邊長").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.1f m", walk.squareSideLengthKm * 1000))
                    .font(.system(.body, design: .monospaced))
            }
            HStack {
                Text("一圈").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(formatLoopTime(walk.squareLoopMinutes))
                    .font(.system(.body, design: .monospaced))
            }
            Text("依速度自動算（margin 20%、一圈 6:00）")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func formatLoopTime(_ minutes: Double) -> String {
        let total = Int(round(minutes * 60.0))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: - Draw control (freeDraw v2)

    private var drawControlSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("畫圖控制")
            HStack {
                Button("開始畫圖") { startDrawing() }
                    .disabled(isDrawing)
                Button("結束畫圖") { finishDrawing() }
                    .disabled(!isDrawing)
                Button("上一步") { undoLastStroke() }
                    .disabled(!isDrawing || drawingStrokes.isEmpty)
            }
            Text(isDrawing
                 ? "拖滑鼠畫筆、抬手結束一筆。≥10m 才採樣。"
                 : "先移動與縮放地圖確定位置 → 按開始畫圖")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func startDrawing() {
        walk.clearQueue()                  // 清舊 path → 觸發 onChange + MapClickView re-render 把藍虛線拔掉
        drawingStrokes.removeAll()
        isDrawing = true
    }

    private func finishDrawing() {
        let path: [CLLocationCoordinate2D] = drawingStrokes.flatMap { $0 }
        if path.count >= 2 {
            let mapped = path.map { Coordinate(lat: $0.latitude, lon: $0.longitude) }
            walk.replaceTargets(with: mapped)
        }
        drawingStrokes.removeAll()
        isDrawing = false
    }

    private func undoLastStroke() {
        guard !drawingStrokes.isEmpty else { return }
        drawingStrokes.removeLast()
    }

    /// freeDraw mode 下、queue 有 path 時把 coords 傳給 MapClickView 畫藍虛線。
    /// 其他 mode return nil（不畫）。
    private var freeDrawPolylineCoords: [Coordinate]? {
        guard walk.mode == .freeDraw else { return nil }
        guard !walk.queue.targets.isEmpty else { return nil }
        return walk.queue.targets.map { $0.coordinate }
    }

    // MARK: - Walk section

    private var walkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("路徑佇列")
            if walk.queue.targets.isEmpty {
                Text("尚未加點").font(.caption).foregroundStyle(.secondary)
            } else {
                List {
                    ForEach(walk.queue.targets) { target in
                        WalkTargetRow(target: target, onDelete: {
                            walk.removeTarget(id: target.id)
                        })
                    }
                    .onMove { src, dst in walk.moveTargets(from: src, to: dst) }
                }
                .listStyle(.bordered)
                .frame(height: min(CGFloat(walk.queue.targets.count) * 32 + 20, 220))
            }

            sectionHeader("速度 \(String(format: "%.1f", walk.queue.speedKmh)) km/h")
            Slider(value: Binding(
                get: { walk.queue.speedKmh },
                set: { walk.setSpeed($0) }
            ), in: 4...20, step: 0.5)
            if walk.queue.speedKmh > 7 {
                Text("⚠ 超過 7 km/h 可能被遊戲懷疑")
                    .font(.caption).foregroundStyle(.red)
            }

            HStack {
                Button("開始走") { attemptStartWalk() }
                    .disabled(walk.queue.targets.isEmpty || walk.queue.running)
                Button("停止") { walk.cancel() }
                    .disabled(!walk.queue.running)
                Button("清空") { walk.clearQueue() }
                    .disabled(walk.queue.targets.isEmpty)
            }

            // 連線中斷時原地重試，走路不會停 —— 但要讓使用者看得到正在發生什麼，
            // 否則畫面上就只是「地圖不動了」。
            if let stall = walk.stallReason {
                Label(stall, systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if let reason = walk.lastStopReason {
                Label(reason, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Toggle("走路時連動步數更新", isOn: $walkStepTrigger.enabled)
                        .toggleStyle(.checkbox)
                        .help("走路期間每 20 秒透過 Mac「捷徑」→ iCloud 專注模式同步 → iPhone「捷徑」自動化 → 寫入「健康」app 步數樣本。詳細說明請看文件。")
                    Spacer()
                    if walkStepTrigger.enabled && walk.queue.running && !walk.queue.paused {
                        Circle().fill(.green).frame(width: 8, height: 8)
                            .help("Trigger loop running")
                    }
                }
                Text("先在 Mac「捷徑」建好 FlipStepFocus 才能用")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Emergency

    private var emergencySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeader("緊急")
            Button(role: .destructive) {
                walk.cancel()
                Task { await status.stopSpoof() }
            } label: {
                Text("恢復真實 GPS")
                    .frame(maxWidth: .infinity)
            }
            .disabled(!status.isSpoofing)
        }
    }

    // MARK: - Helpers

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var latValid: Bool {
        guard let v = Double(latText.trimmingCharacters(in: .whitespaces)) else { return false }
        return (-90.0...90.0).contains(v)
    }

    private var lonValid: Bool {
        guard let v = Double(lonText.trimmingCharacters(in: .whitespaces)) else { return false }
        return (-180.0...180.0).contains(v)
    }

    private var coordsValid: Bool { latValid && lonValid }

    private func handleMapTap(_ coord: CLLocationCoordinate2D) {
        let c = Coordinate(lat: coord.latitude, lon: coord.longitude)
        switch walk.mode {
        case .teleport:
            Task { await status.inject(lat: c.lat, lon: c.lon) }
        case .walk:
            walk.addTarget(at: c)
        case .squareCruise:
            walk.spawnSquare(at: c)
            zoomFitSquare(anchor: c)
            confirmInjectToAnchor(coord: c)
        case .freeDraw:
            break  // 拖拉才有效、單擊忽略
        }
    }

    /// 切到 squareCruise mode 之後、點地圖生 ABCD 之後 zoom 進去把方形塞進視野。
    private func zoomFitSquare(anchor: Coordinate) {
        let x = walk.squareSideLengthKm
        let dLat = x / 111.0
        let dLon = x / (111.0 * cos(anchor.lat * .pi / 180.0))
        let center = CLLocationCoordinate2D(
            latitude: anchor.lat - dLat / 2.0,
            longitude: anchor.lon - dLon / 2.0
        )
        let span = MKCoordinateSpan(
            latitudeDelta: dLat * 1.6,
            longitudeDelta: dLon * 1.6
        )
        centerRequest = CenterRequest(id: UUID(), coordinate: center, span: span)
    }

    /// 點 A 後跳對話框問是否 inject GPS 到 A、取消則清空 queue。
    private func confirmInjectToAnchor(coord: Coordinate) {
        let alert = NSAlert()
        alert.messageText = "注入到 A 點？"
        alert.informativeText = String(
            format: "方形已生成（邊長 %.1f m、一圈 6:00）。\n注入 GPS 到 A = (%.5f, %.5f)？\n取消則清空方形。",
            walk.squareSideLengthKm * 1000.0,
            coord.lat, coord.lon
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "確定")
        alert.addButton(withTitle: "取消")
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            Task { await status.inject(lat: coord.lat, lon: coord.lon) }
        } else {
            walk.clearQueue()
        }
    }

    /// squareCruise mode + 4 點時、targets[0] 視為 A，提供給 MapClickView 標 anchor。
    private var squareAnchorId: UUID? {
        guard walk.mode == .squareCruise, walk.queue.targets.count == 4 else { return nil }
        return walk.queue.targets[0].id
    }

    /// squareCruise mode + 4 點時、回傳 ABCD 給 MapClickView 畫 polygon overlay。
    private var squareCornersForOverlay: [Coordinate]? {
        guard walk.mode == .squareCruise, walk.queue.targets.count == 4 else { return nil }
        return walk.queue.targets.map { $0.coordinate }
    }

    private func attemptStartWalk() {
        if walk.mode == .squareCruise && walk.squareLoopMinutes < 5.0 {
            let alert = NSAlert()
            alert.messageText = "方形太小、跑一圈太快"
            alert.informativeText = String(
                format: "以速度 %.1f km/h 跑邊長 %.1f m 的方形、一圈約 %.1f 分鐘、低於 5 分鐘規則。\n請降速或重新點地圖生新方形。",
                walk.queue.speedKmh,
                walk.squareSideLengthKm * 1000.0,
                walk.squareLoopMinutes
            )
            alert.alertStyle = .warning
            alert.addButton(withTitle: "知道了")
            alert.runModal()
            return
        }
        Task {
            do { try await walk.startWalk() }
            catch { showWalkError(error) }
        }
    }

    private func applyCoordInput() {
        guard
            let lat = Double(latText.trimmingCharacters(in: .whitespaces)),
            let lon = Double(lonText.trimmingCharacters(in: .whitespaces))
        else { return }
        let coord = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        centerRequest = CenterRequest(id: UUID(), coordinate: coord)
        walk.mode = .teleport
        Task { await status.inject(lat: lat, lon: lon) }
    }

    private func runLocationSearch() {
        let q = locationQuery.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        Task { await search.run(query: q, region: currentRegion) }
    }

    private func selectSearchResult(_ item: SearchResult) {
        centerRequest = CenterRequest(id: UUID(), coordinate: item.coordinate)
        walk.mode = .teleport
        Task {
            await status.inject(
                lat: item.coordinate.latitude,
                lon: item.coordinate.longitude
            )
        }
        locationQuery = item.name
        search.dismiss()
    }

    private func showWalkError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "無法開始走路"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    // MARK: - GMap URL parser

    private func runGMapParse() {
        let raw = gmapURL.trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { return }
        gmapBusy = true
        Task {
            defer { Task { @MainActor in gmapBusy = false } }
            do {
                let coord = try await GMapURLParser.parse(raw)
                await MainActor.run {
                    confirmGMapInject(coord: coord)
                }
            } catch {
                await MainActor.run {
                    showGMapError(error)
                }
            }
        }
    }

    private func confirmGMapInject(coord: CLLocationCoordinate2D) {
        centerRequest = CenterRequest(id: UUID(), coordinate: coord)
        let alert = NSAlert()
        alert.messageText = "預覽位置"
        alert.informativeText = String(
            format: "解析到座標 %.5f, %.5f。\n是否注入此位置？",
            coord.latitude, coord.longitude
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: "注入")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            walk.mode = .teleport
            Task { await status.inject(lat: coord.latitude, lon: coord.longitude) }
        }
    }

    private func showGMapError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "無法解析 Google Maps URL"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }
}

// MARK: - Direct inject tab enum

enum DirectInjectTab: Hashable {
    case search
    case coord
    case gmap
}

// MARK: - Google Maps URL parser

enum GMapURLParser {
    enum ParseError: LocalizedError {
        case invalidURL
        case noCoordinates
        case networkFailure(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:        return "URL 格式不正確"
            case .noCoordinates:     return "URL 內找不到經緯度（試過 @lat,lon、!3d!4d、q=、ll= 等格式）"
            case .networkFailure(let m): return "短網址解析失敗：\(m)"
            }
        }
    }

    /// 從多種 Google Maps URL 形式抽 (lat, lon)。短網址會 follow 30x redirect 拿展開後 URL。
    static func parse(_ urlString: String) async throws -> CLLocationCoordinate2D {
        let candidates: [String] = try await {
            if isShortURL(urlString) {
                let expanded = try await resolveShortURL(urlString)
                return [expanded, urlString]
            }
            return [urlString]
        }()

        for s in candidates {
            if let c = extractCoordinate(from: s) { return c }
        }
        throw ParseError.noCoordinates
    }

    private static func isShortURL(_ s: String) -> Bool {
        return s.contains("goo.gl/maps") || s.contains("maps.app.goo.gl")
    }

    private static func resolveShortURL(_ s: String) async throws -> String {
        guard let url = URL(string: s) else { throw ParseError.invalidURL }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let httpResp = response as? HTTPURLResponse, let final = httpResp.url {
                return final.absoluteString
            }
            return s
        } catch {
            throw ParseError.networkFailure(error.localizedDescription)
        }
    }

    /// 依序試各種 pattern，回傳第一個 match 到的座標。
    private static func extractCoordinate(from s: String) -> CLLocationCoordinate2D? {
        let patterns: [String] = [
            #"!3d(-?\d+\.\d+)!4d(-?\d+\.\d+)"#,    // /place/.../!3d<lat>!4d<lon>
            #"@(-?\d+\.\d+),(-?\d+\.\d+)"#,        // /@lat,lon,zoom
            #"[?&]q=(-?\d+\.\d+),(-?\d+\.\d+)"#,   // ?q=lat,lon
            #"[?&]ll=(-?\d+\.\d+),(-?\d+\.\d+)"#,  // ?ll=lat,lon
            #"[?&]center=(-?\d+\.\d+)%2C(-?\d+\.\d+)"#, // ?center=lat%2Clon
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(s.startIndex..., in: s)
            guard let match = regex.firstMatch(in: s, range: range),
                  match.numberOfRanges >= 3,
                  let latR = Range(match.range(at: 1), in: s),
                  let lonR = Range(match.range(at: 2), in: s),
                  let lat = Double(s[latR]),
                  let lon = Double(s[lonR]),
                  (-90.0...90.0).contains(lat),
                  (-180.0...180.0).contains(lon)
            else { continue }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }
}

// MARK: - Walk target row

struct WalkTargetRow: View {
    @ObservedObject var target: WalkTarget
    let onDelete: () -> Void

    var body: some View {
        HStack {
            statusIcon
            Text(target.label).font(.body)
            Spacer()
            Text(statusText).font(.caption).foregroundStyle(.secondary)
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 2)
    }

    private var statusIcon: some View {
        let (system, color): (String, Color) = {
            switch target.status {
            case .pending:     return ("circle", .secondary)
            case .walking:     return ("figure.walk", .blue)
            case .waitingUser: return ("hand.raised.fill", .orange)
            case .done:        return ("checkmark.circle.fill", .green)
            }
        }()
        return Image(systemName: system).foregroundStyle(color)
    }

    private var statusText: String {
        switch target.status {
        case .pending:     return "待走"
        case .walking:     return "走路中"
        case .waitingUser: return "請按繼續"
        case .done:        return "完成"
        }
    }
}

// MARK: - Coordinate makes Identifiable for .alert(item:)

extension Coordinate: Identifiable {
    public var id: String { "\(lat),\(lon)" }
}

// MARK: - Center request

struct CenterRequest: Equatable {
    let id: UUID
    let coordinate: CLLocationCoordinate2D
    /// 自訂 zoom span。nil 表示沿用 map 當前 span（pan only、不 zoom）。
    let span: MKCoordinateSpan?

    init(id: UUID, coordinate: CLLocationCoordinate2D, span: MKCoordinateSpan? = nil) {
        self.id = id
        self.coordinate = coordinate
        self.span = span
    }

    static func == (lhs: CenterRequest, rhs: CenterRequest) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Search

struct SearchResult: Identifiable {
    let id = UUID()
    let name: String
    let address: String
    let coordinate: CLLocationCoordinate2D
}

@MainActor
final class SearchController: ObservableObject {
    @Published var results: [SearchResult] = []
    @Published var lastQueryHadNoResults: Bool = false

    func run(query: String, region: MKCoordinateRegion) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.region = region

        let search = MKLocalSearch(request: request)
        do {
            let response = try await search.start()
            let center = CLLocation(
                latitude: region.center.latitude,
                longitude: region.center.longitude
            )
            let sorted = response.mapItems
                .map { item -> (MKMapItem, Double) in
                    let c = item.placemark.coordinate
                    let dist = CLLocation(latitude: c.latitude, longitude: c.longitude)
                        .distance(from: center)
                    return (item, dist)
                }
                .sorted { $0.1 < $1.1 }
                .prefix(5)

            let mapped = sorted.map { (item, _) -> SearchResult in
                SearchResult(
                    name: item.name ?? item.placemark.name ?? "未命名",
                    address: formatAddress(item.placemark),
                    coordinate: item.placemark.coordinate
                )
            }
            self.results = mapped
            self.lastQueryHadNoResults = mapped.isEmpty
        } catch {
            self.results = []
            self.lastQueryHadNoResults = true
        }
    }

    func dismiss() {
        results = []
        lastQueryHadNoResults = false
    }

    private func formatAddress(_ p: MKPlacemark) -> String {
        let parts = [p.subLocality, p.locality, p.administrativeArea, p.country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Map view

struct MapClickView: NSViewRepresentable {
    let preview: Coordinate?
    let spoofed: Coordinate?
    let waypoints: [WalkTarget]
    /// 標 waypoints 內第幾個是「方形起點 A」、視覺差異化。nil 表示無 anchor。
    let anchorWaypointId: UUID?
    /// 方形四角座標（順序 A→B→C→D）。傳了就畫虛線方形 overlay。
    let squareCorners: [Coordinate]?
    /// freeDraw v2：完成畫圖後的 walk queue path，畫成藍色虛線 polyline。
    let polylineCoords: [Coordinate]?
    /// freeDraw v2：是否處於畫圖模式（true → hide 所有 waypoint marker）。
    let isFreeDrawMode: Bool
    let centerRequest: CenterRequest?
    /// 將 MKMapView 的 reference 提供給 DrawingCanvasView 做螢幕點 ↔ 經緯度轉換。
    let mapRef: MapViewRef
    let onTap: (CLLocationCoordinate2D) -> Void
    let onRegionChange: (MKCoordinateRegion) -> Void

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 24.1477, longitude: 120.6736),
            span: MKCoordinateSpan(latitudeDelta: 0.3, longitudeDelta: 0.3)
        )
        let click = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleClick(_:))
        )
        click.numberOfClicksRequired = 1
        click.delaysPrimaryMouseButtonEvents = false
        map.addGestureRecognizer(click)

        context.coordinator.map = map
        mapRef.map = map
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onRegionChange = onRegionChange
        // map ref 每次 update 也對齊一次（保險：avoid stale）
        mapRef.map = map

        // Annotation diff — 只加新 / 刪舊 / 改 status 才重建，
        // 避免每次 queue 微動就 nuke 全部觸發 MapKit 動畫 churn。
        // freeDraw mode 下、所有 waypoint marker 隱藏（path 用藍虛線 polyline 取代）。
        var desired: [String: KindAnnotation] = [:]
        if let s = spoofed {
            let a = KindAnnotation(kind: .spoofed)
            a.coordinate = CLLocationCoordinate2D(latitude: s.lat, longitude: s.lon)
            a.title = "注入中"
            desired[a.key] = a
        }
        if let p = preview {
            let a = KindAnnotation(kind: .preview)
            a.coordinate = CLLocationCoordinate2D(latitude: p.lat, longitude: p.lon)
            a.title = "預覽"
            desired[a.key] = a
        }
        if !isFreeDrawMode {
            for w in waypoints {
                let kind: KindAnnotation.Kind = (w.id == anchorWaypointId)
                    ? .squareAnchor
                    : .waypoint(status: w.status)
                let a = KindAnnotation(kind: kind, waypointId: w.id)
                a.coordinate = CLLocationCoordinate2D(latitude: w.coordinate.lat, longitude: w.coordinate.lon)
                a.title = w.label
                desired[a.key] = a
            }
        }

        let existing = map.annotations.compactMap { $0 as? KindAnnotation }
        var existingKeys: Set<String> = []
        var toRemove: [KindAnnotation] = []
        for ann in existing {
            let k = ann.key
            if let target = desired[k] {
                // 同 key 已存在 → 更新座標 / title（避免 user 拖 marker 之類 case）
                if ann.coordinate.latitude != target.coordinate.latitude
                    || ann.coordinate.longitude != target.coordinate.longitude {
                    ann.coordinate = target.coordinate
                }
                if ann.title != target.title { ann.title = target.title }
                existingKeys.insert(k)
            } else {
                toRemove.append(ann)
            }
        }
        if !toRemove.isEmpty {
            map.removeAnnotations(toRemove)
        }
        let toAdd = desired.filter { !existingKeys.contains($0.key) }.map { $0.value }
        if !toAdd.isEmpty {
            map.addAnnotations(toAdd)
        }

        // Polygon overlay diff — 4 corners 變或 nil 才 rebuild、避免 SwiftUI re-render 閃爍
        let existingPoly = map.overlays.compactMap { $0 as? MKPolygon }.first
        let desiredCoords: [CLLocationCoordinate2D]? = squareCorners.map { arr in
            arr.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
        let polygonSame: Bool = {
            switch (existingPoly, desiredCoords) {
            case (nil, nil): return true
            case (nil, _?), (_?, nil): return false
            case (let e?, let d?):
                guard e.pointCount == d.count else { return false }
                let pts = e.points()
                for i in 0..<d.count {
                    let p = pts[i].coordinate
                    if abs(p.latitude - d[i].latitude) > 1e-7
                        || abs(p.longitude - d[i].longitude) > 1e-7 {
                        return false
                    }
                }
                return true
            }
        }()
        if !polygonSame {
            if let e = existingPoly { map.removeOverlay(e) }
            if let d = desiredCoords, d.count == 4 {
                map.addOverlay(MKPolygon(coordinates: d, count: d.count))
            }
        }

        // freeDraw v2 polyline diff — 藍虛線 path overlay。
        let existingLine = map.overlays.compactMap { $0 as? MKPolyline }.first
        let desiredLineCoords: [CLLocationCoordinate2D]? = polylineCoords.map { arr in
            arr.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lon) }
        }
        let polylineSame: Bool = {
            switch (existingLine, desiredLineCoords) {
            case (nil, nil): return true
            case (nil, _?), (_?, nil): return false
            case (let e?, let d?):
                guard e.pointCount == d.count else { return false }
                let pts = e.points()
                for i in 0..<d.count {
                    let p = pts[i].coordinate
                    if abs(p.latitude - d[i].latitude) > 1e-7
                        || abs(p.longitude - d[i].longitude) > 1e-7 {
                        return false
                    }
                }
                return true
            }
        }()
        if !polylineSame {
            if let e = existingLine { map.removeOverlay(e) }
            if let d = desiredLineCoords, d.count >= 2 {
                map.addOverlay(MKPolyline(coordinates: d, count: d.count))
            }
        }

        if let req = centerRequest, req.id != context.coordinator.lastAppliedCenterID {
            context.coordinator.lastAppliedCenterID = req.id
            map.setRegion(
                MKCoordinateRegion(center: req.coordinate, span: req.span ?? map.region.span),
                animated: true
            )
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onRegionChange: onRegionChange)
    }

    final class KindAnnotation: MKPointAnnotation {
        enum Kind {
            case preview, spoofed, squareAnchor
            case waypoint(status: WalkTarget.Status)
        }
        let kind: Kind
        /// 暫存 waypoint 的 WalkTarget id（waypoint / squareAnchor 才有）— 用於 diff 識別。
        let waypointId: UUID?

        init(kind: Kind, waypointId: UUID? = nil) {
            self.kind = kind
            self.waypointId = waypointId
            super.init()
        }

        /// 在 desired dict 跟 existing annotation 比對用的 stable identifier。
        /// 包 status 進去 — status 變化視為 identity 變化、觸發重建 (style refresh)
        var key: String {
            switch kind {
            case .preview: return "preview"
            case .spoofed: return "spoofed"
            case .squareAnchor: return "squareAnchor-\(waypointId?.uuidString ?? "?")"
            case .waypoint(let s):
                return "waypoint-\(waypointId?.uuidString ?? "?")-\(s.rawValue)"
            }
        }
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        weak var map: MKMapView?
        var onTap: (CLLocationCoordinate2D) -> Void
        var onRegionChange: (MKCoordinateRegion) -> Void
        var lastAppliedCenterID: UUID?

        init(
            onTap: @escaping (CLLocationCoordinate2D) -> Void,
            onRegionChange: @escaping (MKCoordinateRegion) -> Void
        ) {
            self.onTap = onTap
            self.onRegionChange = onRegionChange
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let map = map else { return }
            let point = gesture.location(in: map)
            let coord = map.convert(point, toCoordinateFrom: map)
            spawnRipple(at: point, in: map)
            onTap(coord)
        }

        /// 點地圖時的即時 ripple 視覺回饋 — 點下去 user 立即看到「我收到了」、
        /// 不用等 SwiftUI re-render + MKMapView pin drop 動畫才有 acknowledgment。
        private func spawnRipple(at point: CGPoint, in map: MKMapView) {
            map.wantsLayer = true
            let endRadius: CGFloat = 32
            let ring = CAShapeLayer()
            ring.frame = CGRect(
                x: point.x - endRadius, y: point.y - endRadius,
                width: endRadius * 2, height: endRadius * 2
            )
            ring.path = CGPath(
                ellipseIn: CGRect(x: 0, y: 0, width: endRadius * 2, height: endRadius * 2),
                transform: nil
            )
            ring.fillColor = NSColor.clear.cgColor
            ring.strokeColor = NSColor.systemBlue.withAlphaComponent(0.9).cgColor
            ring.lineWidth = 2.5
            map.layer?.addSublayer(ring)

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.1
            scale.toValue = 1.0
            let opacity = CABasicAnimation(keyPath: "opacity")
            opacity.fromValue = 1.0
            opacity.toValue = 0.0
            let group = CAAnimationGroup()
            group.animations = [scale, opacity]
            group.duration = 0.45
            group.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(group, forKey: "ripple")

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak ring] in
                ring?.removeFromSuperlayer()
            }
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            onRegionChange(mapView.region)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let kind = (annotation as? KindAnnotation)?.kind else { return nil }
            let id = "kind-\(kindReuseKey(kind))"
            let view: MKMarkerAnnotationView
            if let dq = mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView {
                view = dq
                view.annotation = annotation
            } else {
                view = MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: id)
            }
            switch kind {
            case .preview:
                view.markerTintColor = .systemBlue
                view.glyphImage = NSImage(systemSymbolName: "mappin", accessibilityDescription: nil)
                view.zPriority = .max
            case .spoofed:
                view.markerTintColor = .systemRed
                view.glyphImage = NSImage(systemSymbolName: "location.fill", accessibilityDescription: nil)
                view.zPriority = .min
                view.displayPriority = .defaultHigh
            case .squareAnchor:
                view.markerTintColor = .systemPurple
                view.glyphImage = NSImage(systemSymbolName: "flag.fill", accessibilityDescription: nil)
                view.zPriority = MKAnnotationViewZPriority(rawValue: 800)
            case .waypoint(let status):
                let (color, sym) = waypointStyle(for: status)
                view.markerTintColor = color
                view.glyphImage = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
                view.zPriority = MKAnnotationViewZPriority(rawValue: 750)
            }
            return view
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let polygon = overlay as? MKPolygon {
                let renderer = MKPolygonRenderer(polygon: polygon)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 2.0
                renderer.lineDashPattern = [6, 4]
                renderer.fillColor = NSColor.systemBlue.withAlphaComponent(0.05)
                return renderer
            }
            if let polyline = overlay as? MKPolyline {
                // freeDraw v2 完成後的 walk queue path — 藍色虛線。
                let renderer = MKPolylineRenderer(polyline: polyline)
                renderer.strokeColor = .systemBlue
                renderer.lineWidth = 3.0
                renderer.lineDashPattern = [6, 4]
                renderer.lineCap = .round
                renderer.lineJoin = .round
                return renderer
            }
            return MKOverlayRenderer(overlay: overlay)
        }

        private func kindReuseKey(_ kind: KindAnnotation.Kind) -> String {
            switch kind {
            case .preview: return "preview"
            case .spoofed: return "spoofed"
            case .squareAnchor: return "squareAnchor"
            case .waypoint(let s): return "waypoint-\(s.rawValue)"
            }
        }

        private func waypointStyle(for status: WalkTarget.Status) -> (NSColor, String) {
            switch status {
            case .pending:     return (.systemGray, "circle")
            case .walking:     return (.systemBlue, "figure.walk")
            case .waitingUser: return (.systemOrange, "hand.raised.fill")
            case .done:        return (.systemGreen, "checkmark")
            }
        }
    }
}

// MARK: - Drawing canvas (freeDraw v2)

/// 持有 MKMapView weak reference，給 DrawingCanvasView 做螢幕點 ↔ 經緯度轉換。
final class MapViewRef: ObservableObject {
    weak var map: MKMapView?
}

/// 半透明 overlay 畫布。active drawing 期間蓋在 MKMapView 上、攔截滑鼠事件。
/// strokes 為 lat/lon source of truth（resize 也對得齊）；每筆 stroke 內相鄰兩點
/// ≥ 10m 才採樣。多筆 stroke 在預覽時用紅色直線連起來。
struct DrawingCanvasView: NSViewRepresentable {
    @Binding var strokes: [[CLLocationCoordinate2D]]
    let mapRef: MapViewRef

    func makeNSView(context: Context) -> DrawingCanvasNSView {
        let view = DrawingCanvasNSView()
        view.mapRef = mapRef
        view.onStrokesChange = { newStrokes in
            // bounce through MainActor — strokes is SwiftUI @State
            DispatchQueue.main.async {
                self.strokes = newStrokes
            }
        }
        view.strokes = strokes
        return view
    }

    func updateNSView(_ view: DrawingCanvasNSView, context: Context) {
        view.mapRef = mapRef
        // 外部來的 strokes 更新（如 undo），同步進 view 並重繪。
        view.strokes = strokes
        view.needsDisplay = true
    }
}

/// 實際的 NSView：handle mouseDown/Dragged/Up + 紅色 stroke 預覽 + 半透明灰底。
final class DrawingCanvasNSView: NSView {
    weak var mapRef: MapViewRef?
    /// stroke 內每兩點最小距離（m）— 下採樣避免一條曲線變上百點。
    private let minSampleDistanceM: CLLocationDistance = 10.0
    /// 外部讀寫的 strokes（lat/lon source of truth）。
    var strokes: [[CLLocationCoordinate2D]] = [] {
        didSet { needsDisplay = true }
    }
    /// 把當前 strokes 變動回傳給 SwiftUI binding。
    var onStrokesChange: (([[CLLocationCoordinate2D]]) -> Void)?

    override var isFlipped: Bool { false }  // 維持 macOS bottom-left origin，配合 MKMapView convert

    override func draw(_ dirtyRect: NSRect) {
        // 半透明灰底（user 看得到 map 在底下、操作不到 map）。
        NSColor.gray.withAlphaComponent(0.3).setFill()
        bounds.fill()

        guard let map = mapRef?.map else { return }
        let pinkLine = NSColor.systemPink

        // 把 strokes 內每個 coord 轉成 canvas point。
        func canvasPoint(_ coord: CLLocationCoordinate2D) -> CGPoint {
            let mapPt = map.convert(coord, toPointTo: map)
            let windowPt = map.convert(mapPt, to: nil)
            return self.convert(windowPt, from: nil)
        }

        // 跨 stroke 也用紅線直連 — 跟 finish 時 flatMap 的 path 邏輯一致。
        let path = NSBezierPath()
        path.lineWidth = 3.0
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        var hasMove = false
        for stroke in strokes {
            for coord in stroke {
                let pt = canvasPoint(coord)
                if !hasMove {
                    path.move(to: pt)
                    hasMove = true
                } else {
                    path.line(to: pt)
                }
            }
        }
        pinkLine.setStroke()
        path.stroke()
    }

    // MARK: - Mouse events

    override func mouseDown(with event: NSEvent) {
        guard let coord = coord(from: event) else { return }
        strokes.append([coord])
        onStrokesChange?(strokes)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let coord = coord(from: event) else { return }
        guard var last = strokes.last else { return }
        if let lastPoint = last.last {
            let lastLoc = CLLocation(latitude: lastPoint.latitude, longitude: lastPoint.longitude)
            let curLoc = CLLocation(latitude: coord.latitude, longitude: coord.longitude)
            if curLoc.distance(from: lastLoc) < minSampleDistanceM { return }
        }
        last.append(coord)
        strokes[strokes.count - 1] = last
        onStrokesChange?(strokes)
    }

    override func mouseUp(with event: NSEvent) {
        // 結束當前 stroke、no-op（onStrokesChange 已經在 down/dragged 持續同步）
    }

    /// 把 NSEvent 的滑鼠座標轉成 MKMapView 的經緯度。
    private func coord(from event: NSEvent) -> CLLocationCoordinate2D? {
        guard let map = mapRef?.map else { return nil }
        let windowPt = event.locationInWindow
        let mapPt = map.convert(windowPt, from: nil)
        return map.convert(mapPt, toCoordinateFrom: map)
    }
}
