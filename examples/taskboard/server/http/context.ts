import type { Services } from "../services.ts";
import type { Session } from "../domain/accounts.ts";
export interface RouteContext {
	req: Request;
	parts: string[];
	method: string;
	services: Services;
	session: Session;
	userId: number;
}
