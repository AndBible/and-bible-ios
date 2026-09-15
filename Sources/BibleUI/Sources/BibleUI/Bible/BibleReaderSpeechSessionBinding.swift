// BibleReaderSpeechSessionBinding.swift -- Active-reader speech reconstruction wiring

import BibleCore

/**
 Installs the active reader as the single source of speech-provider reconstruction.

 The service owns process-persisted checkpoints and transport state, while the active controller
 owns installed source resolution and source-specific document navigation. All callbacks resolve
 the active controller at invocation time so workspace/window changes cannot retain a stale pane.
 */
enum BibleReaderSpeechSessionBinding {
    /**
     Wires resume, persisted reconstruction, stopped Play, and stopped-settings callbacks.

     - Parameters:
       - service: Shared provider-driven speech service.
       - activeController: Late-bound lookup for the currently active reader pane.
     - Side effects: Replaces all reader-owned reconstruction callbacks on `service` and updates its
       bookmark persistence owner whenever a callback resolves a controller.
     - Failure modes: Missing active controllers or deallocated services fail closed; no source is
       reconstructed from a stale pane or legacy provider-only callback.
     - Important: Installation and every controller lookup are main-actor isolated so callback
       ownership stays aligned with `SpeakService` and the active reader UI.
     */
    @MainActor
    static func install(
        on service: SpeakService,
        activeController: @escaping @MainActor () -> BibleReaderController?
    ) {
        service.onRequestProviderReconstruction = nil
        service.onRequestDefaultProvider = nil
        service.onRequestSessionReconstruction = { [weak service] checkpoint in
            guard let service, let controller = activeController() else { return nil }
            service.bookmarkManager = controller.bookmarkService
            return controller.reconstructSpeechSession(from: checkpoint, service: service)
        }
        service.onRequestDefaultSession = { [weak service] in
            guard let service, let controller = activeController() else { return nil }
            service.bookmarkManager = controller.bookmarkService
            return controller.defaultSpeechSession(service: service)
        }
        service.onRequestStoppedBibleBookmarkPosition = { [weak service] in
            guard let service, let controller = activeController() else { return nil }
            service.bookmarkManager = controller.bookmarkService
            return controller.stoppedBibleSpeechPosition(service: service)
        }
        service.onRequestResumeBookmark = { [weak service] bookmark in
            guard let generation = service?.currentSessionGeneration else { return }
            Task { @MainActor in
                guard let service,
                      service.currentSessionGeneration == generation,
                      let controller = activeController() else { return }
                service.bookmarkManager = controller.bookmarkService
                controller.resumeSpeech(from: bookmark)
            }
        }
    }
}
