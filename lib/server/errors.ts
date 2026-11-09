export class UserError extends Error {
  readonly status: number;

  readonly code: string;

  constructor(message: string, status = 400, code = "user") {
    super(message);
    this.name = "UserError";
    this.status = status;
    this.code = code;
  }
}

export function publicError(cause: unknown, fallback: string): string {
  rethrowFrameworkError(cause);
  if (cause instanceof UserError) return cause.message;
  return fallback;
}

function rethrowFrameworkError(cause: unknown): void {
  if (typeof cause !== "object" || cause === null || !("digest" in cause)) return;
  const digest = String((cause as { digest?: unknown }).digest);
  if (digest.startsWith("NEXT_")) throw cause;
}
