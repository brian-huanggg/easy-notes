// Image paste: only an image without accompanying text is taken over
import assert from "node:assert/strict";
import { test } from "node:test";
import { MAX_PASTE_BYTES, pastedImage } from "../src/markdown/pasteImage";

const file = (type: string, size = 10) => ({ type, size }) as File;
const data = (types: string[], files: File[]) => ({ types, files }) as unknown as DataTransfer;

test("a screenshot (image only) is taken over", () => {
  const png = file("image/png");
  assert.equal(pastedImage(data(["Files"], [png])), png);
});

test("text next to the image is left to CM6", () => {
  assert.equal(pastedImage(data(["text/plain", "Files"], [file("image/png")])), null);
});

test("non-image files and oversized images are ignored", () => {
  assert.equal(pastedImage(data(["Files"], [file("application/pdf")])), null);
  assert.equal(pastedImage(data(["Files"], [file("image/png", MAX_PASTE_BYTES + 1)])), null);
  assert.equal(pastedImage(null), null);
});
