/**
 * native-bridge.ts — Platform abstraction layer for AndBible
 *
 * Detects whether we're running in an Android WebView or iOS WKWebView
 * and routes native bridge calls to the correct platform API.
 *
 * Android: window.android.methodName(args...)
 * iOS:     window.webkit.messageHandlers.bibleView.postMessage({ method, args })
 *
 * Async responses use the same pattern on both platforms:
 *   window.bibleView.response(callId, returnValue)
 */

import type {BibleJavascriptInterface} from "@/composables/android";

// --- Platform Detection ---

declare global {
    interface Window {
        android?: BibleJavascriptInterface;
        webkit?: {
            messageHandlers?: {
                bibleView?: {
                    postMessage(body: { method: string; args: any[] }): void;
                };
            };
        };
        bibleView: any;
        bibleViewDebug: any;
        __PLATFORM__?: string;
    }
}

export type Platform = "android" | "ios" | "browser";

/**
 * Detect the current platform.
 */
export function detectPlatform(): Platform {
    if (window.__PLATFORM__ === "ios") return "ios";
    if (window.webkit?.messageHandlers?.bibleView) return "ios";
    if (window.android) return "android";
    return "browser";
}

/** Cached platform detection result. */
let _platform: Platform | null = null;

export function getPlatform(): Platform {
    if (_platform === null) {
        _platform = detectPlatform();
    }
    return _platform;
}

export const isIOS = (): boolean => getPlatform() === "ios";
export const isAndroid = (): boolean => getPlatform() === "android";
export const isBrowser = (): boolean => getPlatform() === "browser";

// --- Synchronous Bridge Calls ---

/**
 * Call a native method (fire-and-forget, no return value).
 *
 * @param method - The method name (must match the native handler).
 * @param args - Arguments to pass to the native method.
 */
export function callNative(method: string, ...args: any[]): void {
    const platform = getPlatform();

    if (platform === "ios") {
        window.webkit?.messageHandlers?.bibleView?.postMessage({ method, args });
    } else if (platform === "android") {
        const fn = (window.android as any)?.[method];
        if (typeof fn === "function") {
            fn.apply(window.android, args);
        } else {
            console.warn(`[native-bridge] Android method not found: ${method}`);
        }
    } else {
        // Browser fallback — log to console for development
        console.debug(`[native-bridge] ${method}(${args.map(a => JSON.stringify(a)).join(", ")})`);
    }
}

/**
 * Call a native method that returns a value synchronously.
 * Only works on Android (JavascriptInterface supports synchronous returns).
 * On iOS, this returns undefined — use callNativeAsync instead.
 *
 * @param method - The method name.
 * @param args - Arguments.
 * @returns The return value (Android) or undefined (iOS/browser).
 */
export function callNativeSync(method: string, ...args: any[]): any {
    const platform = getPlatform();

    if (platform === "android") {
        const fn = (window.android as any)?.[method];
        if (typeof fn === "function") {
            return fn.apply(window.android, args);
        }
    }

    // iOS WKScriptMessageHandler doesn't support synchronous returns.
    // Use callNativeAsync for operations that need a response.
    return undefined;
}

// --- Asynchronous Bridge Calls ---

/** Counter for generating unique call IDs. */
let nextCallId = 1;

/** Map of pending async call promises. */
const pendingCalls = new Map<number, {
    resolve: (value: any) => void;
    reject: (reason: any) => void;
}>();

/**
 * Initialize the async response handler.
 * Must be called once during app initialization.
 */
export function initAsyncBridge(): void {
    // Ensure bibleView object exists
    if (!window.bibleView) {
        window.bibleView = {};
    }

    // Register the response handler
    window.bibleView.response = (callId: number, returnValue: any) => {
        const pending = pendingCalls.get(callId);
        if (pending) {
            pending.resolve(returnValue);
            pendingCalls.delete(callId);
        } else {
            console.warn(`[native-bridge] No pending call for callId: ${callId}`);
        }
    };
}

/**
 * Call a native async method and return a Promise that resolves
 * when the native side calls bibleView.response(callId, value).
 *
 * @param method - The method name.
 * @param args - Additional arguments (callId is prepended automatically).
 * @returns Promise resolving to the native response value.
 */
export function callNativeAsync(method: string, ...args: any[]): Promise<any> {
    return new Promise((resolve, reject) => {
        const callId = nextCallId++;
        pendingCalls.set(callId, { resolve, reject });

        // Call native with callId as the first argument
        callNative(method, callId, ...args);

        // Timeout after 60 seconds
        setTimeout(() => {
            if (pendingCalls.has(callId)) {
                pendingCalls.delete(callId);
                reject(new Error(`[native-bridge] Timeout for ${method} (callId: ${callId})`));
            }
        }, 60000);
    });
}

// --- Convenience: Console Logging ---

/**
 * Patch console methods to route logs to the native logging system.
 */
export function patchConsoleForNative(): void {
    const platform = getPlatform();
    if (platform === "browser") return;

    const originalConsole = {
        log: console.log.bind(console),
        warn: console.warn.bind(console),
        error: console.error.bind(console),
        debug: console.debug.bind(console),
        info: console.info.bind(console),
    };

    const sendLog = (level: string, ...args: any[]) => {
        const message = args.map(a =>
            typeof a === "object" ? JSON.stringify(a) : String(a)
        ).join(" ");
        callNative("console", level, message);
    };

    console.log = (...args) => { originalConsole.log(...args); sendLog("log", ...args); };
    console.warn = (...args) => { originalConsole.warn(...args); sendLog("warn", ...args); };
    console.error = (...args) => { originalConsole.error(...args); sendLog("error", ...args); };
    console.debug = (...args) => { originalConsole.debug(...args); sendLog("debug", ...args); };
    console.info = (...args) => { originalConsole.info(...args); sendLog("info", ...args); };
}
