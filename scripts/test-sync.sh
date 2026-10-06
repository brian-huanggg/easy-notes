#!/bin/sh
# Runs the SupabaseSync integration tests (RPC concurrency, RLS, end-to-end sync) against a local Supabase.
# Requires Docker; the first `supabase start` downloads the images.
set -e
cd "$(dirname "$0")/.."
supabase status >/dev/null 2>&1 || supabase start
eval "$(supabase status -o env | grep -E '^(API_URL|PUBLISHABLE_KEY)=')"
export SUPABASE_TEST_URL="$API_URL" SUPABASE_TEST_KEY="$PUBLISHABLE_KEY"
cd Packages/SupabaseSync && swift test "$@"
