export class UserError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UserError";
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
