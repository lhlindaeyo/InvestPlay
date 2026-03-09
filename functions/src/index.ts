import * as functions from "firebase-functions/v2/https";
import { onSchedule } from "firebase-functions/v2/scheduler";
import * as admin from "firebase-admin";
import axios from "axios";

admin.initializeApp();
const db = admin.firestore();

// ─────────────────────────────────────────────────────────
// 환경변수 (.env 파일에서 읽어옴)
// ─────────────────────────────────────────────────────────
const KIS_APP_KEY = process.env.KIS_APP_KEY ?? "";
const KIS_APP_SECRET = process.env.KIS_APP_SECRET ?? "";

// ─────────────────────────────────────────────────────────
// 상수
// ─────────────────────────────────────────────────────────
const KIS_BASE_URL = "https://openapivts.koreainvestment.com:29443"; // 모의투자
const TOKEN_DOC = "config/kisToken";
const TOKEN_EXPIRE_BUFFER_MS = 10 * 60 * 1000; // 만료 10분 전 갱신

interface KisToken {
  accessToken: string;
  expiresAt: number;
}

// ─────────────────────────────────────────────────────────
// 토큰 발급
// ─────────────────────────────────────────────────────────
async function issueNewToken(): Promise<KisToken> {
  const res = await axios.post(
    `${KIS_BASE_URL}/oauth2/tokenP`,
    {
      grant_type: "client_credentials",
      appkey: KIS_APP_KEY,
      appsecret: KIS_APP_SECRET,
    },
    { headers: { "Content-Type": "application/json" } }
  );

  const { access_token, expires_in } = res.data;
  const expiresAt = Date.now() + expires_in * 1000;

  await db.doc(TOKEN_DOC).set({ accessToken: access_token, expiresAt });
  console.log("[KIS] 새 토큰 발급 완료, 만료:", new Date(expiresAt).toISOString());
  return { accessToken: access_token, expiresAt };
}

// ─────────────────────────────────────────────────────────
// 토큰 가져오기 (캐시 우선, 만료 시 자동 갱신)
// ─────────────────────────────────────────────────────────
async function getValidToken(): Promise<string> {
  const snap = await db.doc(TOKEN_DOC).get();

  if (snap.exists) {
    const cached = snap.data() as KisToken;
    if (cached.expiresAt - Date.now() > TOKEN_EXPIRE_BUFFER_MS) {
      console.log("[KIS] 캐시 토큰 사용, 남은:", Math.round((cached.expiresAt - Date.now()) / 60000), "분");
      return cached.accessToken;
    }
    console.log("[KIS] 토큰 만료 임박, 재발급");
  }

  const newToken = await issueNewToken();
  return newToken.accessToken;
}

// ─────────────────────────────────────────────────────────
// 공통 KIS GET 헬퍼
// ─────────────────────────────────────────────────────────
async function kisGet(
  path: string,
  trId: string,
  params: Record<string, string>
): Promise<unknown> {
  const token = await getValidToken();

  const res = await axios.get(`${KIS_BASE_URL}${path}`, {
    headers: {
      Authorization: `Bearer ${token}`,
      appkey: KIS_APP_KEY,
      appsecret: KIS_APP_SECRET,
      tr_id: trId,
      "Content-Type": "application/json; charset=utf-8",
    },
    params,
  });
  return res.data;
}

// ─────────────────────────────────────────────────────────
// [Function 1] 주식 현재가
// ─────────────────────────────────────────────────────────
export const getStockPrice = functions.onRequest(
  { region: "asia-northeast3" },
  async (req, res) => {
    res.set("Access-Control-Allow-Origin", "*");
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }

    try {
      const code = req.query.code as string;
      if (!code) { res.status(400).json({ error: "code 파라미터 필요" }); return; }

      const data = await kisGet(
        "/uapi/domestic-stock/v1/quotations/inquire-price",
        "VTTC8334R",
        { FID_COND_MRKT_DIV_CODE: "J", FID_INPUT_ISCD: code }
      );
      res.json(data);
    } catch (err) {
      console.error("[getStockPrice]", err);
      res.status(500).json({ error: "주식 현재가 조회 실패" });
    }
  }
);

// ─────────────────────────────────────────────────────────
// [Function 2] 일봉/주봉/월봉 차트
// ─────────────────────────────────────────────────────────
export const getStockChart = functions.onRequest(
  { region: "asia-northeast3" },
  async (req, res) => {
    res.set("Access-Control-Allow-Origin", "*");
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }

    try {
      const code = req.query.code as string;
      const period = (req.query.period as string) || "D";
      if (!code) { res.status(400).json({ error: "code 파라미터 필요" }); return; }

      const today = new Date();
      const oneYearAgo = new Date(today);
      oneYearAgo.setFullYear(today.getFullYear() - 1);
      const fmt = (d: Date) => d.toISOString().slice(0, 10).replace(/-/g, "");

      const data = await kisGet(
        "/uapi/domestic-stock/v1/quotations/inquire-daily-itemchartprice",
        "VTTC8411R",
        {
          FID_COND_MRKT_DIV_CODE: "J",
          FID_INPUT_ISCD: code,
          FID_INPUT_DATE_1: fmt(oneYearAgo),
          FID_INPUT_DATE_2: fmt(today),
          FID_PERIOD_DIV_CODE: period,
          FID_ORG_ADJ_PRC: "0",
        }
      );
      res.json(data);
    } catch (err) {
      console.error("[getStockChart]", err);
      res.status(500).json({ error: "차트 데이터 조회 실패" });
    }
  }
);

// ─────────────────────────────────────────────────────────
// [Function 3] 종목 검색
// ─────────────────────────────────────────────────────────
export const searchStock = functions.onRequest(
  { region: "asia-northeast3" },
  async (req, res) => {
    res.set("Access-Control-Allow-Origin", "*");
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }

    try {
      const query = req.query.query as string;
      if (!query) { res.status(400).json({ error: "query 파라미터 필요" }); return; }

      const data = await kisGet(
        "/uapi/domestic-stock/v1/quotations/search-stock-info",
        "CTPF1702R",
        { PRDT_TYPE_CD: "300", PDNO: query }
      );
      res.json(data);
    } catch (err) {
      console.error("[searchStock]", err);
      res.status(500).json({ error: "종목 검색 실패" });
    }
  }
);

// ─────────────────────────────────────────────────────────
// [Function 4] 토큰 수동 갱신 (관리자용)
// ─────────────────────────────────────────────────────────
export const refreshKisToken = functions.onRequest(
  { region: "asia-northeast3" },
  async (req, res) => {
    res.set("Access-Control-Allow-Origin", "*");
    if (req.method === "OPTIONS") { res.status(204).send(""); return; }

    try {
      const token = await issueNewToken();
      res.json({ success: true, expiresAt: new Date(token.expiresAt).toISOString() });
    } catch (err) {
      console.error("[refreshKisToken]", err);
      res.status(500).json({ error: "토큰 갱신 실패" });
    }
  }
);

// ─────────────────────────────────────────────────────────
// [Function 5] 매일 오전 8시 자동 갱신 스케줄러
// ─────────────────────────────────────────────────────────
export const scheduledTokenRefresh = onSchedule(
  {
    schedule: "0 8 * * *",
    timeZone: "Asia/Seoul",
    region: "asia-northeast3",
  },
  async () => {
    console.log("[스케줄러] KIS 토큰 자동 갱신 시작");
    await issueNewToken();
    console.log("[스케줄러] KIS 토큰 자동 갱신 완료");
  }
);