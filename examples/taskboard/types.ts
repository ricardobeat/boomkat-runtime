export interface User {
	id: number;
	name: string;
	email: string;
}
export interface Team {
	id: number;
	name: string;
	owner_id: number;
}
export interface Board {
	id: number;
	name: string;
	team_id: number;
}
export interface List {
	id: number;
	name: string;
	board_id: number;
	position: number;
}
export interface Card {
	id: number;
	list_id: number;
	title: string;
	description: string;
	color: string;
	updated: number;
}
export interface Image {
	id: number;
	card_id: number;
	name: string;
	mime: string;
	size: number;
}
export interface BoardData {
	board: Board;
	lists: List[];
	cards: Card[];
	images: Image[];
}
export interface Workspace {
	teams: Team[];
	boards: Board[];
}

export type Session = { user: User; csrf: string };
