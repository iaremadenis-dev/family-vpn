declare module "node:sqlite" {
  export class DatabaseSync {
    constructor(path: string);
    exec(sql: string): void;
    prepare(sql: string): StatementSync;
    close(): void;
  }

  interface StatementSync {
    get(...params: SqlValue[]): Record<string, SqlValue> | undefined;
    all(...params: SqlValue[]): Array<Record<string, SqlValue>>;
    run(...params: SqlValue[]): { changes: number | bigint };
  }

  type SqlValue = string | number | bigint | null | Uint8Array;
}
