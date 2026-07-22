/*
 * Copyright (c) 2021-2026 Martin Denham, Tuomas Airaksinen and the AndBible contributors.
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

import { readFileSync } from "node:fs";
import { mount } from "@vue/test-utils";
import MemorizeDocument from "@/components/documents/MemorizeDocument.vue";
import WordBlur from "@/components/memorize/WordBlur.vue";
import WordOrder from "@/components/memorize/WordOrder.vue";
import WordType from "@/components/memorize/WordType.vue";
import { describe, it, expect, beforeEach, vi } from "vitest";
import { MemorizeStateModeEnum } from "@/types/documents";
import { memorizationKey } from "@/types/constants";

const androidMock = vi.hoisted(() => ({
  saveState: vi.fn(),
  markAsMemorized: vi.fn(),
  addMemorizationTarget: vi.fn(),
  unmarkMemorized: vi.fn(),
  removeMemorizationTarget: vi.fn(),
  openReadingProgress: vi.fn(),
  openReadingProgressSettings: vi.fn(),
  speakMemorizationLoop: vi.fn(),
  helpDialog: vi.fn(),
}));

vi.mock("@/composables", () => ({
  useCommon: () => ({
    strings: {
      wordBlur: "Word Blur",
      wordScramble: "Word Scramble",
      wordType: "Type",
      wordOrder: "Order",
      markAsMemorized: "Mark as memorized",
      markedAsMemorized: "Marked as memorized",
      removeFromTargets: "Remove from goals",
      addMemorizationTarget: "Add memorization goal",
      viewReadingProgress: "View reading progress",
      viewReadingProgressSettings: "View reading progress settings",
      listenInLoop: "Listen in loop",
      viewHelp: "View help",
    },
    android: androidMock,
  })
}));

window.ResizeObserver = vi.fn().mockImplementation(() => ({
  observe: vi.fn(),
  unobserve: vi.fn(),
  disconnect: vi.fn(),
}));

describe("MemorizeDocument.vue", () => {
  const verseItems = [
    { key: "verse1", text: "For God so loved the world, that he gave his only Son," },
    { key: "verse2", text: "that whoever believes in him should not perish but have eternal life." }
  ];

  beforeEach(() => {
    vi.clearAllMocks();
  });

  const createMockDocument = (overrides = {}) => ({
    id: "doc1",
    type: "memorize",
    title: "Memory Verse - John 3:16",
    texts: verseItems,
    state: {
      memorize: {
        mode: MemorizeStateModeEnum.BLUR,
        modeConfig: {}
      }
    },
    bookInitials: "KJV",
    v11n: "KJVA",
    osisRef: "John.3.16-John.3.18",
    startOrdinal: 10,
    endOrdinal: 12,
    memorizedOrdinals: [],
    targetOrdinals: [],
    readingProgressSettings: {
      autoMarkMemorized: true,
      memorizeTypeFullWords: false,
      memorizeWordVisibility: "light",
      memorizeErrorHeatmap: true,
      memorizeScrambleHideUsed: false,
      memorizeIncludeReference: true,
    },
    ...overrides
  });

  const createWrapper = (docOverrides = {}) => {
    return mount(MemorizeDocument, {
      props: {
        document: createMockDocument(docOverrides)
      },
      global: {
        provide: {
          [memorizationKey]: {
            memorized: new Set(),
            targets: new Set(),
            mergeData: vi.fn(),
            setupIndicatorRendering: vi.fn(),
          }
        },
        stubs: {
          FontAwesomeIcon: true,
          WordBlur: true,
          WordOrder: true,
          WordScramble: true,
          WordType: true,
        }
      }
    });
  };

  it("hides the title by default when Android include-reference mode is enabled", () => {
    const wrapper = createWrapper();
    expect(wrapper.find("h2").exists()).toBe(false);
  });

  it("renders the title link when include-reference mode is disabled", () => {
    const wrapper = createWrapper({
      readingProgressSettings: { memorizeIncludeReference: false }
    });

    const title = wrapper.find("h2 .title-link");
    expect(title.text()).toBe("Memory Verse - John 3:16");
    expect(title.attributes("href")).toBe("osis://?osis=John.3.16-John.3.18&v11n=KJVA");
  });

  it("renders all Android memorize mode selector buttons", () => {
    const wrapper = createWrapper();
    const buttons = wrapper.findAll(".memorize-mode-selector .tab-button");

    expect(buttons.map(button => button.text())).toEqual([
      "Word Blur",
      "Word Scramble",
      "Type",
      "Order",
    ]);
  });

  /**
   * Protects the Android Memorize presentation contract after iOS routes Memorize into the links
   * pane instead of a full-reader surface.
   *
   * Android's current bibleview bundle provides shared `.icon-button` sizing for Memorize controls
   * and the iOS links pane needs Memorize-specific tab/content spacing so all four mode tabs and the
   * trailing action menu remain visually balanced in a phone-width split window. These declarations
   * are style-source contracts because jsdom cannot compute the SFC/SCSS cascade used by the
   * installed WKWebView bundle.
   */
  it("keeps Android icon controls and compact links-pane tab spacing", () => {
    const commonSource = readFileSync(`${process.cwd()}/src/common.scss`, "utf8");
    const memorizeSource = readFileSync(
      `${process.cwd()}/src/components/documents/MemorizeDocument.vue`,
      "utf8"
    );

    expect(commonSource).toMatch(/\.icon-button\s*\{/);
    expect(commonSource).toContain("min-width: 40px");
    expect(commonSource).toContain("height: 40px");
    expect(commonSource).toContain(".icon-badge");

    expect(memorizeSource).toContain(".memorize-container .tab-content.memorize-content");
    expect(memorizeSource).toContain("padding-top: 0");
    expect(memorizeSource).toContain(".memorize-container .memorize-mode-selector .tab-button");
    expect(memorizeSource).toContain("padding: 10px 8px");
    expect(memorizeSource).toContain(".memorize-container .memorize-text");
    expect(memorizeSource).toContain("line-height: 1.65");
    expect(memorizeSource).toContain("min-width: 40px");
    expect(memorizeSource).toContain("height: 40px");
  });

  it("passes reference-appended text items by default", () => {
    const wrapper = createWrapper();
    const childComponent = wrapper.findComponent(WordBlur);

    expect(childComponent.props("textItems")).toEqual([
      ...verseItems,
      { key: "__reference__", text: "Memory Verse - John 3:16" },
    ]);
    expect(childComponent.props("modeConfig")).toEqual({});
  });

  it("passes only verse text items when include-reference mode is disabled", () => {
    const wrapper = createWrapper({
      readingProgressSettings: { memorizeIncludeReference: false }
    });
    const childComponent = wrapper.findComponent(WordBlur);

    expect(childComponent.props("textItems")).toEqual(verseItems);
  });

  it("restores type mode from document state", () => {
    const wrapper = createWrapper({
      state: {
        memorize: {
          mode: MemorizeStateModeEnum.TYPE,
          modeConfig: {}
        }
      }
    });

    expect(wrapper.find('[id="tabpanel-type"]').isVisible()).toBe(true);
    expect(wrapper.find('[id="tabpanel-blur"]').isVisible()).toBe(false);
  });

  it("restores order mode from document state", () => {
    const wrapper = createWrapper({
      state: {
        memorize: {
          mode: MemorizeStateModeEnum.ORDER,
          modeConfig: {}
        }
      }
    });

    expect(wrapper.find('[id="tabpanel-order"]').isVisible()).toBe(true);
    expect(wrapper.find('[id="tabpanel-blur"]').isVisible()).toBe(false);
  });

  it("saves Android mode state when order mode is selected", async () => {
    const wrapper = createWrapper();
    const buttons = wrapper.findAll(".memorize-mode-selector .tab-button");

    await buttons[3].trigger("click");

    expect(androidMock.saveState).toHaveBeenCalledWith(expect.objectContaining({
      memorize: expect.objectContaining({
        mode: MemorizeStateModeEnum.ORDER,
      })
    }));
  });

  it("auto-marks the verse range memorized when a completion-capable mode finishes", async () => {
    const wrapper = createWrapper();
    const childComponent = wrapper.findComponent(WordType);

    await childComponent.vm.$emit("memorize-completed");

    expect(androidMock.markAsMemorized).toHaveBeenCalledWith("KJV", 10, 12);
  });

  it("does not auto-mark completion when Android progress settings disable it", async () => {
    const wrapper = createWrapper({
      readingProgressSettings: { autoMarkMemorized: false }
    });
    const childComponent = wrapper.findComponent(WordOrder);

    await childComponent.vm.$emit("memorize-completed");

    expect(androidMock.markAsMemorized).not.toHaveBeenCalled();
  });
});
