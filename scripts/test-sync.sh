#!/bin/sh
# 對本地 Supabase 跑 SupabaseSync 整合測試（RPC 併發、RLS、端對端同步）
# 需要 Docker；第一次 `supabase start` 會下載 image。
set -e
cd "$(dirname "$0")/.."
supabase status >/dev/null 2>&1 || supabase start
eval "$(supabase status -o env | grep -E '^(API_URL|PUBLISHABLE_KEY)=')"
export SUPABASE_TEST_URL="$API_URL" SUPABASE_TEST_KEY="$PUBLISHABLE_KEY"
cd Packages/SupabaseSync && swift test "$@"
