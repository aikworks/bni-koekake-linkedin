// LinkedIn声掛けツール: 管理者がメンバーのログインを作る・止める・パスワードを変える。
import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// ログインIDにメールアドレス以外も使えるよう、内部用のアドレスに変換する
const toEmail = (loginId: string) => loginId.includes("@") ? loginId.trim().toLowerCase() : `${loginId.trim().toLowerCase()}@koekake.invalid`;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const jwt = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: { user } } = await admin.auth.getUser(jwt);
  if (!user) return json({ error: "ログインし直してください" }, 401);
  const { data: me } = await admin.from("lk_members").select("*").eq("user_id", user.id).eq("active", true).single();
  if (!me || me.role !== "admin") return json({ error: "管理者だけが使えます" }, 403);

  const b = await req.json().catch(() => ({}));
  if (b.action === "create") {
    if (!b.login_id || !b.password || String(b.password).length < 8 || !b.display_name) {
      return json({ error: "ログインID、8文字以上のパスワード、名前を入れてください" }, 400);
    }
    const { data, error } = await admin.auth.admin.createUser({ email: toEmail(b.login_id), password: b.password, email_confirm: true });
    if (error) return json({ error: error.message.includes("already") ? "そのログインIDは使われています" : error.message }, 400);
    const { error: e2 } = await admin.from("lk_members").insert({
      user_id: data.user.id, chapter_id: me.chapter_id, display_name: b.display_name,
      biz: b.biz ?? "", role: b.role === "admin" ? "admin" : "member",
    });
    if (e2) { await admin.auth.admin.deleteUser(data.user.id); return json({ error: e2.message }, 400); }
    return json({ ok: true });
  }

  // 以下は同じチャプターのメンバーだけ
  const { data: target } = await admin.from("lk_members").select("*").eq("user_id", b.user_id ?? "").eq("chapter_id", me.chapter_id).single();
  if (!target) return json({ error: "メンバーが見つかりません" }, 404);
  if (b.action === "set_active") {
    if (target.user_id === me.user_id) return json({ error: "自分自身は止められません" }, 400);
    await admin.from("lk_members").update({ active: !!b.active }).eq("user_id", target.user_id);
    await admin.auth.admin.updateUserById(target.user_id, { ban_duration: b.active ? "none" : "876000h" });
    return json({ ok: true });
  }
  if (b.action === "set_password") {
    if (!b.password || String(b.password).length < 8) return json({ error: "8文字以上にしてください" }, 400);
    const { error } = await admin.auth.admin.updateUserById(target.user_id, { password: b.password });
    return error ? json({ error: error.message }, 400) : json({ ok: true });
  }
  if (b.action === "set_role") {
    if (target.user_id === me.user_id) return json({ error: "自分の役割は変えられません" }, 400);
    await admin.from("lk_members").update({ role: b.role === "admin" ? "admin" : "member" }).eq("user_id", target.user_id);
    return json({ ok: true });
  }
  return json({ error: "不明な操作です" }, 400);
});
