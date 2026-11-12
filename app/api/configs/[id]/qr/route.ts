import { writeAudit } from "@/lib/server/audit";
import { getConfigDownload } from "@/lib/server/configs";
import { UserError } from "@/lib/server/errors";
import { readSession } from "@/lib/server/session";
import { NextResponse } from "next/server";
import QRCode from "qrcode";

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
    writeAudit("config.download", id);
    const png = await QRCode.toBuffer(file.content, {
      type: "png",
      width: 320,
      margin: 1,
      errorCorrectionLevel: "M",
    });
    return new NextResponse(new Uint8Array(png), {
      status: 200,
      headers: {
        "Content-Type": "image/png",
        "Cache-Control": "no-store",
      },
    });
  } catch (cause) {
    if (cause instanceof UserError) {
      return NextResponse.json({ error: cause.message }, { status: cause.status });
    }
    return NextResponse.json({ error: "Не удалось построить QR-код." }, { status: 500 });
  }
}
