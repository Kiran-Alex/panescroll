#if DEBUG
import AppKit
import SwiftUI

/// Dev aid for README screenshots: windows with made-up content, so no real
/// user windows ever appear in project images.
enum DemoWindows {
    static func open() -> [NSWindow] {
        let specs: [(String, CGFloat, AnyView)] = [
            ("Browser", 628, AnyView(BrowserMock())),
            ("main.swift — Editor", 760, AnyView(EditorMock())),
            ("Terminal", 500, AnyView(TerminalMock())),
            ("Notes", 500, AnyView(NotesMock())),
            ("Chat", 628, AnyView(ChatMock())),
        ]
        return specs.enumerated().map { i, spec in
            let w = NSWindow(contentRect: CGRect(x: 40 + CGFloat(i) * 60, y: 100, width: spec.1, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = spec.0
            let host = NSHostingView(rootView: AnyView(spec.2.frame(minWidth: 0, minHeight: 0, alignment: .topLeading).clipped()))
            host.sizingOptions = [] // no SwiftUI minimum size: resizable to anything
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.makeKeyAndOrderFront(nil)
            return w
        }
    }
}

private func bar(_ w: CGFloat, _ c: Color, h: CGFloat = 8) -> some View {
    RoundedRectangle(cornerRadius: h / 2).fill(c).frame(width: w, height: h)
}

private struct EditorMock: View {
    let lines: [[(CGFloat, Color)]] = [
        [(60, .pink), (120, .white.opacity(0.8))],
        [],
        [(70, .pink), (90, .cyan), (40, .white.opacity(0.5))],
        [(30, .clear), (80, .purple), (140, .orange)],
        [(30, .clear), (60, .purple), (100, .green), (50, .white.opacity(0.5))],
        [(30, .clear), (110, .cyan), (70, .orange)],
        [(10, .white.opacity(0.5))],
        [],
        [(70, .pink), (130, .cyan), (30, .white.opacity(0.5))],
        [(30, .clear), (90, .purple), (60, .white.opacity(0.8)), (80, .green)],
        [(30, .clear), (50, .pink), (160, .orange)],
        [(60, .clear), (120, .cyan), (40, .white.opacity(0.5))],
        [(30, .clear), (10, .white.opacity(0.5))],
        [(10, .white.opacity(0.5))],
        [],
        [(90, .gray)],
        [(70, .pink), (100, .cyan), (30, .white.opacity(0.5))],
        [(30, .clear), (140, .green)],
        [(10, .white.opacity(0.5))],
    ]
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(["Sources", "  App.swift", "  main.swift", "  Strip.swift", "Tests", "README.md"], id: \.self) {
                    Text($0).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity($0.contains("main") ? 1 : 0.55))
                }
                Spacer()
            }
            .padding(14).frame(width: 150).frame(maxHeight: .infinity, alignment: .top).background(Color(white: 0.11))
            VStack(alignment: .leading, spacing: 11) {
                ForEach(lines.indices, id: \.self) { i in
                    HStack(spacing: 6) {
                        Text("\(i + 1)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.gray).frame(width: 18, alignment: .trailing)
                        ForEach(lines[i].indices, id: \.self) { j in bar(lines[i][j].0, lines[i][j].1.opacity(0.85)) }
                    }
                }
                Spacer()
            }
            .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .background(Color(red: 0.09, green: 0.09, blue: 0.12))
    }
}

private struct BrowserMock: View {
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                RoundedRectangle(cornerRadius: 7).fill(Color(white: 0.92)).frame(height: 26)
                    .overlay(Text("example.com/journal").font(.system(size: 11)).foregroundStyle(.secondary))
            }
            .padding(10).background(Color(white: 0.97))
            VStack(alignment: .leading, spacing: 16) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(LinearGradient(colors: [.orange, .pink], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 200)
                bar(320, Color(white: 0.2), h: 16)
                ForEach(0..<6, id: \.self) { i in bar(CGFloat([520, 480, 540, 300, 500, 420][i]), Color(white: 0.8)) }
                HStack(spacing: 12) {
                    ForEach(0..<3, id: \.self) { _ in RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.93)).frame(height: 120) }
                }
                Spacer()
            }
            .padding(24)
        }
        .background(Color.white)
    }
}

private struct TerminalMock: View {
    let lines = ["~/projects/panescroll $ swift build", "Building for debugging...", "[12/12] Compiling PanescrollCore Strip.swift",
                 "Build complete! (3.21s)", "~/projects/panescroll $ swift test",
                 "Executed 30 tests, with 0 failures", "~/projects/panescroll $ ▍"]
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines, id: \.self) { l in
                Text(l).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(l.contains("$") ? Color.green : l.contains("complete") || l.contains("0 failures") ? .cyan : .white.opacity(0.8))
            }
            Spacer()
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(white: 0.06))
    }
}

private struct NotesMock: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Weekend ideas").font(.system(size: 20, weight: .bold))
            ForEach(["Try the new ramen place", "Fix the bike chain", "Plan hiking route", "Call the plumber"], id: \.self) { t in
                HStack { Image(systemName: t.contains("bike") ? "checkmark.circle.fill" : "circle").foregroundStyle(.orange); Text(t) }
                    .font(.system(size: 13))
            }
            Spacer()
        }
        .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(red: 1, green: 0.98, blue: 0.9))
        .foregroundStyle(.black)
    }
}

private struct ChatMock: View {
    let msgs: [(Bool, CGFloat)] = [(false, 220), (true, 160), (false, 280), (true, 120), (false, 200), (true, 240)]
    var body: some View {
        VStack(spacing: 12) {
            ForEach(msgs.indices, id: \.self) { i in
                HStack {
                    if msgs[i].0 { Spacer() }
                    RoundedRectangle(cornerRadius: 14).fill(msgs[i].0 ? Color.blue : Color(white: 0.9))
                        .frame(width: msgs[i].1, height: 34)
                    if !msgs[i].0 { Spacer() }
                }
            }
            Spacer()
        }
        .padding(18).background(Color.white)
    }
}
#endif
