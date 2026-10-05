// Conventional Commits：type 決定 Changelog 的分類（見 cliff.toml），subject 就是使用者看到的那一行。
export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'type-enum': [2, 'always', [
      'feat', 'fix', 'perf', 'security', // 進 Changelog（Added / Fixed / Changed / Security）
      'docs', 'refactor', 'test', 'chore', 'build', 'ci', 'style', 'revert', // 不進 Changelog
    ]],
    // 繁體中文 subject，沒有大小寫與句點的問題
    'subject-case': [0],
    'header-max-length': [2, 'always', 100],
    'body-max-line-length': [0],
    'footer-max-line-length': [0],
  },
}
