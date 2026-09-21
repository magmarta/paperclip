import { describe, expect, it } from "vitest";
import express from "express";
import request from "supertest";
import {
  isSignUpEmailAllowed,
  signUpEmailAllowlistMiddleware,
} from "../middleware/signup-email-allowlist.js";

// magmarta fork policy (i). See .github/FORK-POLICY.md.
describe("isSignUpEmailAllowed", () => {
  it("allows everything when no allowlist is configured", () => {
    expect(isSignUpEmailAllowed("anyone@example.com", [])).toBe(true);
  });

  it("matches an exact address, case-insensitively", () => {
    const list = ["hasan@marta.tr"];
    expect(isSignUpEmailAllowed("hasan@marta.tr", list)).toBe(true);
    expect(isSignUpEmailAllowed("  HASAN@Marta.TR  ", list)).toBe(true);
    expect(isSignUpEmailAllowed("someone@marta.tr", list)).toBe(false);
  });

  it("matches a domain wildcard", () => {
    const list = ["*@marta.tr", "*@martateknoloji.com.tr"];
    expect(isSignUpEmailAllowed("anyone@marta.tr", list)).toBe(true);
    expect(isSignUpEmailAllowed("hasan@martateknoloji.com.tr", list)).toBe(true);
  });

  it("does not let a lookalike domain smuggle itself in", () => {
    const list = ["*@marta.tr"];
    expect(isSignUpEmailAllowed("attacker@evil-marta.tr", list)).toBe(false);
    expect(isSignUpEmailAllowed("attacker@marta.tr.evil.com", list)).toBe(false);
    // A subdomain is not covered by the apex wildcard; list it explicitly.
    expect(isSignUpEmailAllowed("someone@mail.marta.tr", list)).toBe(false);
  });

  it("rejects malformed addresses once a list exists", () => {
    const list = ["*@marta.tr"];
    expect(isSignUpEmailAllowed("", list)).toBe(false);
    expect(isSignUpEmailAllowed("no-at-sign", list)).toBe(false);
    expect(isSignUpEmailAllowed("@marta.tr", list)).toBe(false);
    expect(isSignUpEmailAllowed("hasan@", list)).toBe(false);
  });

  it("compares the address as sent, so a wildcard still covers sub-addressing", () => {
    expect(isSignUpEmailAllowed("hasan+ci@marta.tr", ["*@marta.tr"])).toBe(true);
    expect(isSignUpEmailAllowed("hasan+ci@marta.tr", ["hasan@marta.tr"])).toBe(false);
  });
});

describe("signUpEmailAllowlistMiddleware", () => {
  function appWith(allowlist: string[]) {
    const app = express();
    app.use(express.json());
    app.use("/api/auth", signUpEmailAllowlistMiddleware(allowlist));
    app.all("/api/auth/{*authPath}", (_req, res) => {
      res.status(200).json({ reached: true });
    });
    return app;
  }

  it("blocks a sign-up from outside the allowlist", async () => {
    const res = await request(appWith(["*@marta.tr"]))
      .post("/api/auth/sign-up/email")
      .send({ email: "outsider@example.com", password: "hunter2hunter2" });
    expect(res.status).toBe(403);
    expect(res.body.code).toBe("SIGNUP_EMAIL_NOT_ALLOWED");
  });

  it("lets an allowed address through to the auth handler", async () => {
    const res = await request(appWith(["*@marta.tr"]))
      .post("/api/auth/sign-up/email")
      .send({ email: "hasan@marta.tr", password: "hunter2hunter2" });
    expect(res.status).toBe(200);
    expect(res.body.reached).toBe(true);
  });

  it("blocks a sign-up with a missing or non-string email", async () => {
    const app = appWith(["*@marta.tr"]);
    expect((await request(app).post("/api/auth/sign-up/email").send({})).status).toBe(403);
    expect(
      (await request(app).post("/api/auth/sign-up/email").send({ email: 42 })).status,
    ).toBe(403);
  });

  it("never touches sign-in, sign-out or session paths", async () => {
    const app = appWith(["*@marta.tr"]);
    const signIn = await request(app)
      .post("/api/auth/sign-in/email")
      .send({ email: "outsider@example.com", password: "hunter2hunter2" });
    expect(signIn.status).toBe(200);

    const session = await request(app).get("/api/auth/get-session");
    expect(session.status).toBe(200);
  });

  it("is inert when the allowlist is empty", async () => {
    const res = await request(appWith([]))
      .post("/api/auth/sign-up/email")
      .send({ email: "anyone@example.com", password: "hunter2hunter2" });
    expect(res.status).toBe(200);
  });
});
