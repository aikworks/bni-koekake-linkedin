# LinkedIn声掛けツール（BNI BtoB-Across）

LinkedInで届いたメッセージを貼ると、1to1やビジター参加につながる返信案を3つ作るツールです。送信はメンバーが自分でLinkedInから行います。

- `index.html` / `config.js`: 画面（GitHub Pagesで公開）
- `supabase/schema.sql`: データベースの表と権限（aikworks-dashboard に `lk_` 付きで同居）
- `supabase/functions/lk-generate`: 返信案を作る（Claude API）。Secrets に `ANTHROPIC_API_KEY` が必要。`LK_MODEL` でモデルを変えられる
- `supabase/functions/lk-admin-users`: 管理者がメンバーのログインを発行・停止する
