import type { ExtensionAPI, ExtensionContext, WorkingIndicatorOptions } from "@earendil-works/pi-coding-agent";

const W = 18;
const MATRIX_CHARS = "ﾊﾐﾋｰｳｼﾅﾓﾆｻﾜﾂｵﾘ012789Z";
const GLITCH_CHARS = "█▓▒░╳╱╲¥£€$#@!?&%~*";

function rgb(r: number, g: number, b: number): string {
	return `\x1b[38;2;${r};${g};${b}m`;
}
const RESET = "\x1b[39m";

function generateMatrixFrames(count: number): string[] {
	const frames: string[] = [];
	for (let f = 0; f < count; f++) {
		let line = "";
		for (let i = 0; i < W; i++) {
			const char = MATRIX_CHARS[Math.floor(Math.random() * MATRIX_CHARS.length)]!;
			const intensity = (i - f + count * 2) % (W / 2);
			let color = rgb(0, 80, 0);
			if (intensity < 1) color = rgb(0, 255, 0);
			else if (intensity < 3) color = rgb(0, 160, 0);
			line += color + char;
		}
		frames.push(line + RESET);
	}
	return frames;
}

function generateGlitchFrames(count: number): string[] {
	// Muted Tokyo Night palette (Cyan, Purple, Blue, Yellow/Orange)
	const colors = [rgb(125, 207, 200), rgb(187, 154, 247), rgb(122, 162, 247), rgb(224, 175, 104)];
	const frames: string[] = [];
	for (let f = 0; f < count; f++) {
		let line = "";
		for (let i = 0; i < W; i++) {
			const color = colors[Math.floor(Math.random() * colors.length)]!;
			const char = GLITCH_CHARS[Math.floor(Math.random() * GLITCH_CHARS.length)]!;
			line += color + char;
		}
		frames.push(line + RESET);
	}
	return frames;
}

function generateTypewriterFrames(): string[] {
	return [
		rgb(150, 150, 150) + "..." + RESET,
		rgb(200, 200, 200) + "T.." + RESET,
		rgb(200, 200, 200) + "TY." + RESET,
		rgb(255, 255, 255) + "TYP" + RESET,
		rgb(200, 200, 200) + "YP." + RESET,
		rgb(150, 150, 150) + "P.." + RESET,
	];
}

const matrixFrames = generateMatrixFrames(30);
const glitchFrames = generateGlitchFrames(30);
const typewriterFrames = generateTypewriterFrames();

export default function (pi: ExtensionAPI): void {
	const matrixIndicator: WorkingIndicatorOptions = {
		frames: matrixFrames,
		intervalMs: 80,
	};
	
	const glitchIndicator: WorkingIndicatorOptions = {
		frames: glitchFrames,
		intervalMs: 60,
	};
	
	const typewriterIndicator: WorkingIndicatorOptions = {
		frames: typewriterFrames,
		intervalMs: 150,
	};

	let activeTools = 0;

	pi.registerCommand("cyber", {
		description: "Test cyber-loader animations (matrix, glitch, typewriter, auto)",
		handler: async (args: string, ctx: ExtensionContext): Promise<void> => {
			const mode = args.trim().toLowerCase();
			if (mode === "matrix") {
				ctx.ui.setWorkingIndicator(matrixIndicator);
				ctx.ui.notify("Cyber-loader overridden: Matrix (Working/Idle)", "info");
			} else if (mode === "glitch") {
				ctx.ui.setWorkingIndicator(glitchIndicator);
				ctx.ui.notify("Cyber-loader overridden: Glitch (Tool Execution)", "info");
			} else if (mode === "typewriter") {
				ctx.ui.setWorkingIndicator(typewriterIndicator);
				ctx.ui.notify("Cyber-loader overridden: Typewriter (Thinking)", "info");
			} else if (mode === "auto" || mode === "reset") {
				activeTools = 0;
				ctx.ui.setWorkingIndicator(matrixIndicator);
				ctx.ui.notify("Cyber-loader restored to Auto mode", "info");
			} else {
				ctx.ui.notify("Usage: /cyber [matrix|glitch|typewriter|auto]", "error");
			}
		},
	});

	pi.on("session_start", (_event: any, ctx: ExtensionContext): void => {
		activeTools = 0;
		ctx.ui.setWorkingIndicator(matrixIndicator);
	});

	pi.on("tool_execution_start", (_event: any, ctx: ExtensionContext): void => {
		activeTools++;
		ctx.ui.setWorkingIndicator(glitchIndicator);
	});

	pi.on("tool_execution_end", (_event: any, ctx: ExtensionContext): void => {
		activeTools--;
		if (activeTools <= 0) {
			activeTools = 0;
			ctx.ui.setWorkingIndicator(matrixIndicator);
		}
	});
}
