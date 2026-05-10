/*
 * Copyright (c) 2026 Sykerö Software / Tuomas Airaksinen and the AndBible contributors.
 *
 * This file is part of AndBible: Bible Study (http://github.com/AndBible/and-bible).
 *
 * AndBible is free software: you can redistribute it and/or modify it under the
 * terms of the GNU General Public License as published by the Free Software Foundation,
 * either version 3 of the License, or (at your option) any later version.
 *
 * AndBible is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 * without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
 * See the GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License along with AndBible.
 * If not, see http://www.gnu.org/licenses/.
 */

import {afterEach, beforeEach, describe, expect, it, vi} from "vitest";
import {handleAnchorNavigation} from "@/utils";

describe("link navigation", () => {
    let postMessage;

    beforeEach(() => {
        document.body.innerHTML = "";
        window.__PLATFORM__ = "ios";
        postMessage = vi.fn();
        window.webkit = {
            messageHandlers: {
                bibleView: {postMessage},
            },
        };
    });

    afterEach(() => {
        document.body.innerHTML = "";
        delete window.__PLATFORM__;
        delete window.webkit;
    });

    function dispatchLinkClick(href, beforeDocumentClick) {
        const link = document.createElement("a");
        link.setAttribute("href", href);
        const inner = document.createElement("span");
        inner.textContent = "link";
        link.appendChild(inner);
        document.body.appendChild(link);

        if (beforeDocumentClick) {
            link.addEventListener("click", beforeDocumentClick);
        }

        let handled = false;
        document.addEventListener("click", event => {
            handled = handleAnchorNavigation(event);
        }, {once: true});

        const event = new MouseEvent("click", {bubbles: true, cancelable: true});
        inner.dispatchEvent(event);
        return {event, handled};
    }

    it("routes My Notes links through the iOS bridge", () => {
        const {event, handled} = dispatchLinkClick("my-notes://?ordinal=1&v11n=KJVA");

        expect(handled).toBe(true);
        expect(event.defaultPrevented).toBe(true);
        expect(postMessage).toHaveBeenCalledWith({
            method: "openExternalLink",
            args: ["my-notes://?ordinal=1&v11n=KJVA"],
        });
    });

    it("routes StudyPad links through the iOS bridge", () => {
        const {handled} = dispatchLinkClick("journal://?id=label-id&bookmarkId=bookmark-id");

        expect(handled).toBe(true);
        expect(postMessage).toHaveBeenCalledWith({
            method: "openExternalLink",
            args: ["journal://?id=label-id&bookmarkId=bookmark-id"],
        });
    });

    it("does not hijack component-managed link clicks", () => {
        const {event, handled} = dispatchLinkClick("osis://?osis=Gen.1.1", event => {
            event.preventDefault();
        });

        expect(handled).toBe(false);
        expect(event.defaultPrevented).toBe(true);
        expect(postMessage).not.toHaveBeenCalled();
    });

    it("leaves hash-only links alone", () => {
        const {event, handled} = dispatchLinkClick("#link");

        expect(handled).toBe(false);
        expect(event.defaultPrevented).toBe(false);
        expect(postMessage).not.toHaveBeenCalled();
    });
});
