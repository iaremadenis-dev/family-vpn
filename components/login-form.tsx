"use client";

import { useActionState } from "react";
import { login, setupAdmin, type AuthFormState } from "@/app/actions/auth";
import { Button, Field, inputClass } from "@/components/ui";

export function LoginForm({ mode }: { mode: "setup" | "login" }) {
  const action = mode === "setup" ? setupAdmin : login;
  const [state, submit, pending] = useActionState(action, null as AuthFormState);

  return (
    <main className="flex min-h-dvh items-center justify-center px-4 py-10">
      <form action={submit} className="glass w-full max-w-md px-6 py-6">
        <p className="text-xs font-medium text-accent">Family VPN</p>
        <h1 className="mt-2 text-xl font-semibold text-ink">
          {mode === "setup" ? "Первый запуск" : "Вход администратора"}
        </h1>
        <p className="mt-2 text-sm text-muted">
          {mode === "setup"
            ? "Создаётся единственная учётная запись. Пароль хранится только как хеш в локальной базе."
            : "Одна учётная запись. Пароль VPS сюда не вводится."}
        </p>
        <div className="mt-5 flex flex-col gap-4">
          {mode === "setup" ? (
            <Field id="name" label="Имя">
              <input
                id="name"
                name="name"
                className={inputClass}
                maxLength={40}
                autoComplete="nickname"
                required
              />
            </Field>
          ) : null}
          <Field
            id="password"
            label="Пароль"
            hint={mode === "setup" ? "Не короче 12 символов, с буквой и цифрой." : undefined}
          >
            <input
              id="password"
              name="password"
              type="password"
              className={inputClass}
              autoComplete={mode === "setup" ? "new-password" : "current-password"}
              required
            />
          </Field>
          {mode === "setup" ? (
            <Field id="confirm" label="Пароль ещё раз">
              <input
                id="confirm"
                name="confirm"
                type="password"
                className={inputClass}
                autoComplete="new-password"
                required
              />
            </Field>
          ) : null}
          {state?.error ? <p className="text-sm text-bad">{state.error}</p> : null}
          <Button type="submit" disabled={pending}>
            {pending ? "Проверка…" : mode === "setup" ? "Создать администратора" : "Войти"}
          </Button>
        </div>
      </form>
    </main>
  );
}
