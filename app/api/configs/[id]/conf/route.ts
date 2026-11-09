import { getConfigDownload } from "@/lib/server/configs";
import { UserError } from "@/lib/server/errors";
import { readSession } from "@/lib/server/session";
import { NextResponse } from "next/server";

export async function GET(
  _request: Request,
  context: { params: Promise<{ id: string }> },
) {
  const session = await readSession();
  if (!session) {
    return NextResponse.json({ error: "Требуется вход." }, { status: 401 });
  }
  try {
    const { id } = await context.params;
    const file = await getConfigDownload(id);
    return new NextResponse(file.content, {
      status: 200,
      headers: {
        "Content-Type": "text/plain; charset=utf-8",
        "Content-Disposition": `attachment; filename="${file.fileName}"`,
        "Cache-Control": "no-store",
      },
    });
  } catch (cause) {
    if (cause instanceof UserError) {
      return NextResponse.json({ error: cause.message }, { status: cause.status });
    }
    return NextResponse.json({ error: "Не удалось выдать конфигурацию." }, { status: 500 });
  }
}
