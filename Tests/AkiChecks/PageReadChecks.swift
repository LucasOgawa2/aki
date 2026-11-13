import AkiCore
import Foundation

/// The overlay waiting for a mark's page, and what a mark on a browser records.
@MainActor func pageReadChecks() {
    let sessionA = LinuxMarking.terminal(id: "a", name: "A", worktree: "/a", lastSent: Date(timeIntervalSince1970: 10))
    print("linux marking: page reads")
    let saveElement = LinuxMarking.PageElement(path: "button#save “Save”", tag: "button", text: "Save", id: "save", classes: ["primary"],
                                               source: "src/App.tsx:12", html: "<button id=\"save\">Save</button>", selector: "#save")
    var paging = Overlay(sessions: [sessionA], readsText: true, readsPage: true)
    let pagePoint = paging.handle(.pointer(screen: 0, from: at(10, 10), to: at(10, 10), app: .init(name: "Google-chrome"), onBrowser: true))
    let pagePointID = paging.marks[0].id
    check(pagePoint == .enrich(paging.marks[0], sources: [.page]) && paging.pendingSources(pagePointID) == [.page], "a point on the browser: its page asked, and waited for")
    check(paging.handle(.enriched(id: pagePointID, .init(text: "words"))) == nil && paging.pendingSources(pagePointID) == [.page] && paging.marks[0].selectedText == nil,
          "an answer from a source not asked (its words): ignored")
    _ = paging.handle(.enriched(id: pagePointID, source: .page, .init(url: "http://localhost:3000/", element: saveElement)))
    check(paging.marks[0].url == "http://localhost:3000/" && paging.marks[0].element == saveElement && !paging.isPending(pagePointID), "the page arrives: address and element on the mark")
    _ = paging.handle(.enriched(id: pagePointID, source: .page, .init(url: "http://other/")))
    check(paging.marks[0].url == "http://localhost:3000/", "the same source again: nothing")
    let pageArea = paging.handle(.pointer(screen: 0, from: at(10, 10), to: at(90, 70), app: nil, onBrowser: true))
    let pageAreaID = paging.marks[1].id
    check(pageArea == .enrich(paging.marks[1], sources: [.text, .page]) && paging.pendingSources(pageAreaID) == [.text, .page], "an area on the browser: its words and its page")
    _ = paging.handle(.enriched(id: pageAreaID, .init(text: "Total")))
    check(paging.pendingSources(pageAreaID) == [.page] && paging.marks[1].selectedText == "Total", "its words first: still waiting for the page")
    _ = paging.handle(.enriched(id: pageAreaID, source: .page, .init(url: "http://localhost:3000/", element: saveElement)))
    check(!paging.isPending(pageAreaID) && paging.marks[1].url == "http://localhost:3000/" && paging.marks[1].element == nil, "then the page: an area takes only the address")
    check(paging.handle(.pointer(screen: 0, from: at(5, 5), to: at(5, 5), app: nil, onBrowser: false)) == nil && !paging.isPending(paging.marks[2].id),
          "a point off the browser: nothing asked")
    var noPage = Overlay(sessions: [sessionA], readsText: false)
    check(noPage.handle(.pointer(screen: 0, from: at(5, 5), to: at(5, 5), app: nil, onBrowser: true)) == nil, "pages not read (refused endpoint): a point asks nothing")
    check(noPage.handle(.pointer(screen: 0, from: at(5, 5), to: at(90, 70), app: nil, onBrowser: true)) == nil, "nor an area")
    var pageOnly = Overlay(sessions: [sessionA], readsText: false, readsPage: true)
    check(pageOnly.handle(.pointer(screen: 0, from: at(5, 5), to: at(90, 70), app: nil, onBrowser: true)) == .enrich(pageOnly.marks[0], sources: [.page]),
          "no tesseract: an area on the browser still asks its page")

    var pageWait = Overlay(sessions: [sessionA], readsText: true, readsPage: true)
    _ = pageWait.handle(.pointer(screen: 0, from: at(10, 10), to: at(10, 10), app: nil, onBrowser: true))
    let pageWaitID = pageWait.marks[0].id
    let pageToken = waitToken(pageWait.handle(.send))
    check(pageToken != nil && pageWait.waitingForReads, "Ctrl+Enter with the page still being read: the send waits")
    check(pageWait.handle(.enriched(id: pageWaitID, source: .page, .init())) == .send(pageWait.marks, destination: "a") && pageWait.marks[0].url == nil,
          "the read failed (nothing): sent at once, without page fields")
    check(pageWait.handle(.enriched(id: pageWaitID, source: .page, .init(url: "late"))) == nil && pageWait.handle(.deadline(pageToken ?? -1)) == nil,
          "a late answer and the old timer after: nothing")
    var pageUndo = Overlay(sessions: [sessionA], readsPage: true)
    _ = pageUndo.handle(.pointer(screen: 0, from: at(10, 10), to: at(10, 10), app: nil, onBrowser: true))
    let pageUndoID = pageUndo.marks[0].id
    _ = pageUndo.handle(.undo)
    check(!pageUndo.isPending(pageUndoID) && pageUndo.handle(.enriched(id: pageUndoID, source: .page, .init(url: "x"))) == nil && pageUndo.marks.isEmpty,
          "undone while its page is read: the answer is dropped")
    var pageSlow = Overlay(sessions: [sessionA], readsPage: true)
    _ = pageSlow.handle(.pointer(screen: 0, from: at(10, 10), to: at(10, 10), app: nil, onBrowser: true))
    let slowPageToken = waitToken(pageSlow.handle(.send)) ?? -1
    check(pageSlow.handle(.deadline(slowPageToken)) == .send(pageSlow.marks, destination: "a") && pageSlow.marks[0].element == nil, "3 s up: sent without the element")

    var browserPoint = LinuxMarking.PortableMark(screen: 0, rect: .init(x: 100, y: 200, width: 0, height: 0), comment: "this", number: 1,
                                                 app: .init(name: "Google-chrome", window: "App - Google Chrome"), url: "http://localhost:3000/x", element: saveElement)
    let browserFields = LinuxMarking.fields(of: browserPoint, id: "aki_1_p", batch: "batch_1", terminal: plainSession, imagePath: "/h/p.jpg")
    check(browserFields["url"] == "http://localhost:3000/x" && browserFields["kind"] == "point" && browserFields["selector"] == "#save"
          && browserFields["source_file_path"] == "src/App.tsx:12", "a point's page: url, selector and source file, as on the Mac")
    check(browserFields["element_context"] == ["path": "button#save “Save”", "tag": "button", "text": "Save", "id": "save", "classes": ["primary"],
                                               "source": "src/App.tsx:12", "html": "<button id=\"save\">Save</button>"], "and the element_context the Mac writes")
    browserPoint.element = .init(path: "div.card", tag: "div")
    let bareFields = LinuxMarking.fields(of: browserPoint, id: "aki_1_p", batch: "batch_1", terminal: plainSession, imagePath: "/h/p.jpg")
    check(bareFields["selector"] == "div.card" && bareFields["element_context"] == ["path": "div.card", "tag": "div"] && bareFields["source_file_path"] == nil,
          "no selector: its path; no source: no source_file_path")
    browserPoint.element = nil
    let urlOnly = LinuxMarking.fields(of: browserPoint, id: "aki_1_p", batch: "batch_1", terminal: plainSession, imagePath: "/h/p.jpg")
    check(urlOnly["url"] == "http://localhost:3000/x" && urlOnly["element_context"] == nil && urlOnly["selector"] == nil, "only the address: no element fields")
    check(LinuxMarking.places(of: [Annotation(urlOnly)]) == ["localhost:3000"], "the delivery names the page's host and port")

    let chromeRect = LinuxMarking.Rect(x: 1920, y: 0, width: 1000, height: 800)
    let right = LinuxMarking.Monitor(x: 1920, y: 0, width: 1920, height: 1080)
    check(LinuxMarking.isOnBrowser(.init(x: 100, y: 100, width: 0, height: 0), on: right, window: chromeRect, appName: "Google-chrome"),
          "a point in Chrome's window on the second monitor: on the browser")
    check(LinuxMarking.isOnBrowser(.init(x: 100, y: 100, width: 0, height: 0), on: right, window: chromeRect, appName: "Chromium-browser")
          && LinuxMarking.isOnBrowser(.init(x: 100, y: 100, width: 0, height: 0), on: right, window: chromeRect, appName: "Brave-browser"), "Chromium and Brave too")
    check(!LinuxMarking.isOnBrowser(.init(x: 100, y: 100, width: 0, height: 0), on: right, window: chromeRect, appName: "firefox"), "Firefox: no (no DevTools protocol here)")
    check(!LinuxMarking.isOnBrowser(.init(x: 1200, y: 100, width: 0, height: 0), on: right, window: chromeRect, appName: "Google-chrome"), "beside the window: no")
    check(!LinuxMarking.isOnBrowser(.init(x: 100, y: 100, width: 0, height: 0), on: .init(x: 0, y: 0, width: 1920, height: 1080), window: chromeRect, appName: "Google-chrome"),
          "the same spot on the first monitor: no")
    check(LinuxMarking.isOnBrowser(.init(x: 900, y: 700, width: 180, height: 60), on: right, window: chromeRect, appName: "Google-chrome")
          && !LinuxMarking.isOnBrowser(.init(x: 980, y: 700, width: 180, height: 60), on: right, window: chromeRect, appName: "Google-chrome"),
          "an area: by its centre")
    check(!LinuxMarking.isOnBrowser(.init(x: 100, y: 100, width: 0, height: 0), on: right, window: nil, appName: "Google-chrome"), "no window known: no")

}
