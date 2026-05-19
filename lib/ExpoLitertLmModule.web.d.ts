import type { LiteRtLoadResult, LiteRtPreferredBackend, LiteRtTokenEvent } from './index';
type Listener = (event: LiteRtTokenEvent) => void;
declare class ExpoLitertLmWebModule {
    private litertLm;
    private mediaPipe;
    private runtime;
    private litertLmEngine;
    private litertLmConversation;
    private mediaPipeLlm;
    private loadConfig;
    private activeGenerationId;
    private listeners;
    isAvailableAsync(): Promise<boolean>;
    sampleMemoryAsync(): Promise<number>;
    loadModelAsync(modelPath: string, maxTokens: number, topK: number, temperature: number, preferredBackend?: LiteRtPreferredBackend): Promise<LiteRtLoadResult>;
    generateResponseAsync(prompt: string): Promise<string>;
    generateAudioResponseAsync(_audioPath: string, _prompt: string): Promise<string>;
    cancelGenerateResponseAsync(): Promise<void>;
    unloadModelAsync(): Promise<void>;
    addListener(_eventName: string, listener: Listener): {
        remove: () => void;
    };
    private emit;
    private loadLitertLm;
    private generateLitertLm;
    private loadMediaPipe;
    private generateMediaPipe;
    private requireLitertLm;
    private requireMediaPipe;
    private unloadInternal;
}
declare const expoLitertLmWebModule: ExpoLitertLmWebModule;
export default expoLitertLmWebModule;
//# sourceMappingURL=ExpoLitertLmModule.web.d.ts.map