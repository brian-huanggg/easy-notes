// Image paste: WebKit exposes a copied image (screenshot, Photos, Finder file) as a `File` in `clipboardData`;
// CM6 inserts only text, so without this the paste does nothing.

/** Larger images are not sent over the Bridge (the native side enforces its own limit too) */
export const MAX_PASTE_BYTES = 30 * 1024 * 1024;

/** The image to import for this paste, or null to leave it to CM6 (text paste, or an image with text next to it) */
export function pastedImage(data: Pick<DataTransfer, "types" | "files"> | null): File | null {
  if (!data || Array.from(data.types).includes("text/plain")) return null;
  const file = Array.from(data.files).find((f) => f.type.startsWith("image/"));
  return file && file.size <= MAX_PASTE_BYTES ? file : null;
}

/** Base64 of the file, for the Bridge */
export function toBase64(file: Blob): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result).replace(/^data:[^,]*,/, ""));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(file);
  });
}
