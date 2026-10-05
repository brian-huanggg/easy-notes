// 狀態列的統計與名稱方塊的位置；純函式，不碰 DOM（test/sheetStats.test.ts）

/** A, B, …, Z, AA, AB… */
export function columnName(i: number): string {
  let name = "";
  for (let n = i + 1; n > 0; n = Math.floor((n - 1) / 26)) name = String.fromCharCode(65 + ((n - 1) % 26)) + name;
  return name;
}

const plainNumber = /^[-+]?(?:\d{1,3}(?:,\d{3})+|\d+)?(?:\.\d+)?$/;

/** 只認純數字（正負號、小數點、千分位逗號）；其他（日期、百分比、貨幣）不算數字 */
export function parseNumber(text: string): number | null {
  const s = text.trim();
  if (s === "" || !/\d/.test(s) || !plainNumber.test(s)) return null;
  const n = Number(s.replace(/,/g, ""));
  return Number.isFinite(n) ? n : null;
}

export interface Stats {
  /** 非空白的格數 */
  count: number;
  /** 數字的格數；0 時沒有加總與平均 */
  numbers: number;
  sum: number;
  average: number;
}

export function stats(values: Iterable<string>): Stats {
  let count = 0;
  let numbers = 0;
  let sum = 0;
  for (const value of values) {
    if (value.trim() === "") continue;
    count++;
    const n = parseNumber(value);
    if (n === null) continue;
    numbers++;
    sum += n;
  }
  return { count, numbers, sum, average: numbers > 0 ? sum / numbers : 0 };
}

/** 加總與平均的顯示：浮點誤差（0.1 + 0.2）以有效位數修掉 */
export function formatNumber(n: number, locale: string): string {
  return new Intl.NumberFormat(locale, { maximumFractionDigits: 10 }).format(Number(n.toPrecision(15)));
}
