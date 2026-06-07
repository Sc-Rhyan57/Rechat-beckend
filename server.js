const express = require('express');
const crypto = require('crypto');
const fetch = require('node-fetch');
const helmet = require('helmet');
const cors = require('cors');
const morgan = require('morgan');
const compression = require('compression');
const http = require('http');
const WebSocket = require('ws');
require('dotenv').config();

const app = express();
const server = http.createServer(app);
const wss = new WebSocket.Server({ server });

app.set('trust proxy', 1);
app.use(helmet({ contentSecurityPolicy: false, crossOriginEmbedderPolicy: false }));
app.use(cors({ origin: '*', credentials: true }));
app.use(compression());
app.use(morgan('dev'));
app.use(express.json({ limit: '1mb' }));

const DATABASE_METHOD = process.env.DATABASE_METHOD || 'Firebase';

const MAINTENANCE_MODE = false;
const maintenanceMessagesCache = new Map();

const GITHUB_TOKENS = [
    process.env.GITHUB_TOKEN_1,
    process.env.GITHUB_TOKEN_2,
    process.env.GITHUB_TOKEN_3,
    process.env.GITHUB_TOKEN_4,
    process.env.GITHUB_TOKEN_5,
    process.env.GITHUB_TOKEN_6,
    process.env.GITHUB_TOKEN_7,
    process.env.GITHUB_TOKEN_8,
    process.env.GITHUB_TOKEN_9
].filter(Boolean);

const GITHUB_REPO = process.env.GITHUB_REPO || 'username/rechat-database';
let currentTokenIndex = 0;
const INACTIVE_THRESHOLD = 60 * 60 * 1000;
const MAX_MESSAGE_LENGTH = 200;
const MESSAGE_COOLDOWN = 2000;
const MAX_MESSAGES_PER_MINUTE = 15;
const MAX_FILES_PER_PLACE = 190;
const MAX_JOBS_PER_GAME_FOLDER = 190;
const MAX_JOBS_PER_FOLDER = 20;

const FB_PROJECT_ID = process.env.FIREBASE_PROJECT_ID || '';
const FB_API_KEY    = process.env.FIREBASE_API_KEY    || '';
const FB_BASE_URL   = `https://firestore.googleapis.com/v1/projects/${FB_PROJECT_ID}/databases/(default)/documents`;
let _fbTokenCache   = null;

const getFbToken = async () => {
    if (_fbTokenCache && _fbTokenCache.expires > Date.now() + 60000) return _fbTokenCache.token;
    const res = await fetch(`https://identitytoolkit.googleapis.com/v1/accounts:signInAnonymously?key=${FB_API_KEY}`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ returnSecureToken: true })
    });
    if (!res.ok) throw new Error(`Firebase auth failed: ${res.status}`);
    const data = await res.json();
    _fbTokenCache = { token: data.idToken, expires: Date.now() + (parseInt(data.expiresIn) * 1000) };
    return _fbTokenCache.token;
};

const toFirestoreValue = (val) => {
    if (val === null || val === undefined) return { nullValue: null };
    if (typeof val === 'boolean') return { booleanValue: val };
    if (typeof val === 'number') {
        if (!Number.isInteger(val)) return { doubleValue: val };
        if (val > 9007199254740991 || val < -9007199254740991) return { doubleValue: val };
        return { integerValue: String(val) };
    }
    if (typeof val === 'string') return { stringValue: val };
    if (Array.isArray(val)) return { arrayValue: { values: val.map(toFirestoreValue) } };
    if (typeof val === 'object') {
        const fields = {};
        for (const [k, v] of Object.entries(val)) fields[k] = toFirestoreValue(v);
        return { mapValue: { fields } };
    }
    return { stringValue: String(val) };
};

const fromFirestoreValue = (val) => {
    if ('nullValue'    in val) return null;
    if ('booleanValue' in val) return val.booleanValue;
    if ('integerValue' in val) return parseInt(val.integerValue);
    if ('doubleValue'  in val) return val.doubleValue;
    if ('stringValue'  in val) return val.stringValue;
    if ('arrayValue'   in val) return (val.arrayValue.values || []).map(fromFirestoreValue);
    if ('mapValue'     in val) {
        const obj = {};
        for (const [k, v] of Object.entries(val.mapValue.fields || {})) obj[k] = fromFirestoreValue(v);
        return obj;
    }
    return null;
};

const fbGet = async (collection, docId) => {
    const res = await fetch(`${FB_BASE_URL}/${collection}/${docId}`);
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`Firestore GET ${collection}/${docId}: ${res.status}`);
    const raw = await res.json();
    if (!raw.fields) return null;
    const obj = {};
    for (const [k, v] of Object.entries(raw.fields)) obj[k] = fromFirestoreValue(v);
    return obj;
};

const fbSet = async (collection, docId, data) => {
    const fields = {};
    for (const [k, v] of Object.entries(data)) fields[k] = toFirestoreValue(v);
    const res = await fetch(`${FB_BASE_URL}/${collection}/${docId}`, {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ fields })
    });
    if (!res.ok) {
        const err = await res.text();
        throw new Error(`Firestore SET ${collection}/${docId}: ${res.status} ${err}`);
    }
    return true;
};

const fbDelete = async (collection, docId) => {
    const res = await fetch(`${FB_BASE_URL}/${collection}/${docId}`, { method: 'DELETE' });
    return res.ok;
};

const gameJobCounts = new Map();
const wsClients = new Map();

const broadcastToJob = (jobId, data) => {
    const clients = wsClients.get(jobId);
    if (!clients || clients.size === 0) return;
    const payload = JSON.stringify(data);
    for (const ws of clients) {
        if (ws.readyState === WebSocket.OPEN) ws.send(payload);
    }
};

class CacheManager {
    constructor() { this.jobCaches = new Map(); }
    getJobCache(jobId) {
        if (!this.jobCaches.has(jobId)) this.jobCaches.set(jobId, new Map());
        return this.jobCaches.get(jobId);
    }
    get(jobId, key)        { return this.getJobCache(jobId).get(key); }
    set(jobId, key, value) { this.getJobCache(jobId).set(key, value); }
    delete(jobId, key)     { this.getJobCache(jobId).delete(key); }
    clear(jobId)           { this.jobCaches.delete(jobId); }
    getStats() {
        const stats = {};
        for (const [jobId, c] of this.jobCaches.entries()) stats[jobId] = c.size;
        return stats;
    }
}

const cache             = new CacheManager();
const placeIdMap        = new Map();
const userMessageTimes  = new Map();
const userMessageCounts = new Map();
let mappingsLoaded      = false;

const task = { spawn: (fn) => { setImmediate(() => { fn().catch(err => console.error('[TASK_SPAWN]', err)); }); } };

const getNextToken = () => GITHUB_TOKENS[currentTokenIndex++ % GITHUB_TOKENS.length];

const generateHWID = (req) => {
    const components = [req.headers['user-agent'] || '', req.headers['accept-language'] || '', req.ip || ''];
    return crypto.createHash('sha256').update(components.join('|')).digest('hex');
};

const BLOCKED_WORDS = [
    'dick','nigga','fuck','bitch','ass','shit','porn','sex','nigge','nigger','niggar',
    'porra','fode','sexo','negro','hittler','pussy','buceta','negro','viado','viadinho',
    'biscate','boiola','bicha','bixa','fuck','foder','Fuck','bucetinha'
];

const CHAR_MAP = {
    'a':'@4áàâãäå','e':'3€éèêë','i':'1!|íìîï','o':'0óòôõö',
    's':'$5š','g':'9','l':'1|','t':'7+','b':'8','c':'<(çk',
    'k':'<c','u':'úùûü','n':'ñ','y':'ýÿ','z':'2'
};

const normalize = (char) => {
    const lower = char.toLowerCase();
    for (const [base, subs] of Object.entries(CHAR_MAP)) { if (subs.includes(lower)) return base; }
    return lower;
};

const filterMessage = (message) => {
    let filtered = message.trim();
    const urlPatterns = [
        /discord\.gg\/[a-zA-Z0-9]+/gi,
        /discord\.com\/invite\/[a-zA-Z0-9]+/gi,
        /(https?:\/\/)?([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}(\/[^\s]*)?/gi
    ];
    for (const pattern of urlPatterns) filtered = filtered.replace(pattern, (match) => '*'.repeat(match.length));

    const normalized      = filtered.toLowerCase().split('').map(c => normalize(c)).join('');
    const cleanedForCheck = normalized.replace(/[\s._\-*]/g, '');

    for (const word of BLOCKED_WORDS) {
        let positions = [], searchPos = 0;
        for (let i = 0; i < word.length; i++) {
            let found = false;
            for (let j = searchPos; j < filtered.length; j++) {
                const nc = normalize(filtered[j].toLowerCase());
                if (nc === word[i]) { positions.push(j); searchPos = j + 1; found = true; break; }
                else if (/[a-z0-9]/i.test(filtered[j])) break;
            }
            if (!found) { positions = []; break; }
        }
        if (positions.length === word.length) {
            const start = positions[0], end = positions[positions.length - 1], span = end - start + 1;
            if (span <= word.length + 6) filtered = filtered.substring(0, start) + '*****' + filtered.substring(end + 1);
        }
    }

    for (const word of BLOCKED_WORDS) {
        if (cleanedForCheck.includes(word)) {
            const wordRegex = new RegExp(word.split('').join('[\\s._\\-*]{0,2}'), 'gi');
            filtered = filtered.replace(wordRegex, '*****');
        }
    }
    return filtered;
};

const githubFetch = async (path, method = 'GET', body = null) => {
    const token = getNextToken();
    const url   = `https://api.github.com/repos/${GITHUB_REPO}/contents/${path}`;
    const options = {
        method,
        headers: { 'Authorization': `token ${token}`, 'Accept': 'application/vnd.github.v3+json', 'Content-Type': 'application/json' }
    };
    if (body) options.body = JSON.stringify(body);
    const response = await fetch(url, options);
    if (!response.ok) throw new Error(`GitHub API error: ${response.status}`);
    return await response.json();
};

const githubGet = async (path, defaultData = null) => {
    try {
        const data    = await githubFetch(path);
        const content = Buffer.from(data.content, 'base64').toString('utf-8');
        return { data: JSON.parse(content), sha: data.sha };
    } catch (error) {
        if (error.message.includes('404')) {
            if (defaultData !== null) {
                try { return await githubCreate(path, defaultData); }
                catch (createError) {
                    if (createError.message.includes('409') || createError.message.includes('422')) {
                        const data    = await githubFetch(path);
                        const content = Buffer.from(data.content, 'base64').toString('utf-8');
                        return { data: JSON.parse(content), sha: data.sha };
                    }
                    throw createError;
                }
            }
            return { data: defaultData, sha: null };
        }
        throw error;
    }
};

const githubCreate = async (path, data) => {
    const response = await githubFetch(path, 'PUT', {
        message: 'Initialize',
        content: Buffer.from(JSON.stringify(data, null, 2)).toString('base64')
    });
    return { data, sha: response.content.sha };
};

const githubUpdate = async (path, data, sha, retries = 3) => {
    for (let attempt = 0; attempt < retries; attempt++) {
        try {
            const response = await githubFetch(path, 'PUT', {
                message: 'Update',
                content: Buffer.from(JSON.stringify(data, null, 2)).toString('base64'),
                sha
            });
            return { success: true, sha: response.content.sha };
        } catch (error) {
            if (error.message.includes('409') || error.message.includes('422')) {
                const { data: currentData, sha: newSha } = await githubGet(path);
                sha = newSha;
                if (attempt === retries - 1) return { success: false, data: currentData, sha: newSha };
                continue;
            }
            if (attempt === retries - 1) return { success: false };
            await new Promise(r => setTimeout(r, 1000 * (attempt + 1)));
        }
    }
    return { success: false };
};

const githubDeleteFolder = async (path) => {
    const token       = getNextToken();
    const contentsUrl = `https://api.github.com/repos/${GITHUB_REPO}/contents/${path}`;
    try {
        const response = await fetch(contentsUrl, { headers: { 'Authorization': `token ${token}`, 'Accept': 'application/vnd.github.v3+json' } });
        if (!response.ok) return false;
        const files = await response.json();
        for (const file of files) {
            if (file.type === 'dir') await githubDeleteFolder(file.path);
            else await fetch(`https://api.github.com/repos/${GITHUB_REPO}/contents/${file.path}`, {
                method: 'DELETE',
                headers: { 'Authorization': `token ${token}`, 'Accept': 'application/vnd.github.v3+json', 'Content-Type': 'application/json' },
                body: JSON.stringify({ message: 'Auto cleanup', sha: file.sha })
            });
        }
        return true;
    } catch (error) { console.error('[DELETE_FOLDER] Error:', error.message); return false; }
};

const getNextGameFolder = async (placeId) => {
    let count = gameJobCounts.get(placeId) || { current: 1, jobsInFolder: 0 };
    if (count.jobsInFolder >= MAX_JOBS_PER_GAME_FOLDER) { count.current++; count.jobsInFolder = 0; }
    gameJobCounts.set(placeId, count);
    return count.current;
};

const dbGetMappings = async () => {
    if (DATABASE_METHOD === 'Firebase') {
        const doc = await fbGet('rechat_meta', 'jobid_to_placeid');
        return { data: doc?.mappings || {}, sha: null };
    }
    return await githubGet('mappings/jobid_to_placeid.json', {});
};

const dbSetMappings = async (mappings, sha) => {
    if (DATABASE_METHOD === 'Firebase') {
        await fbSet('rechat_meta', 'jobid_to_placeid', { mappings });
        return { success: true, sha: null };
    }
    return await githubUpdate('mappings/jobid_to_placeid.json', mappings, sha);
};

const dbGetServerInfo = async (placeId, jobId, defaultData) => {
    if (DATABASE_METHOD === 'Firebase') {
        const data = await fbGet('rechat_jobs', `${placeId}_${jobId}`);
        return { data: data || defaultData, sha: null };
    }
    const gameFolder = await getNextGameFolder(placeId);
    return await githubGet(`games/${gameFolder}/${jobId}/server_info.json`, defaultData);
};

const dbSetServerInfo = async (placeId, jobId, data, sha) => {
    if (DATABASE_METHOD === 'Firebase') {
        await fbSet('rechat_jobs', `${placeId}_${jobId}`, data);
        return { success: true, sha: null };
    }
    const gameFolder = await getNextGameFolder(placeId);
    return await githubUpdate(`games/${gameFolder}/${jobId}/server_info.json`, data, sha);
};

const dbGetMessages = async (placeId, jobId, chatType, chatId) => {
    if (DATABASE_METHOD === 'Firebase') {
        const docId = chatType === 'general' ? 'general' : `private_${chatId}`;
        const doc = await fbGet(`rechat_jobs/${placeId}_${jobId}/chats`, docId);
        const raw = doc?.messages;
        const parsed = Array.isArray(raw) ? raw : (typeof raw === 'string' ? JSON.parse(raw) : []);
        return { data: parsed, sha: null };
    }
    const gameFolder = await getNextGameFolder(placeId);
    const path = chatType === 'general'
        ? `games/${gameFolder}/${jobId}/chats/general.json`
        : `games/${gameFolder}/${jobId}/chats/private/${chatId}.json`;
    return await githubGet(path, []);
};

const dbSetMessages = async (placeId, jobId, chatType, chatId, messages, sha) => {
    if (DATABASE_METHOD === 'Firebase') {
        const docId = chatType === 'general' ? 'general' : `private_${chatId}`;
        await fbSet(`rechat_jobs/${placeId}_${jobId}/chats`, docId, { messages: messages, updated: Date.now() });
        return { success: true, sha: null };
    }
    const gameFolder = await getNextGameFolder(placeId);
    const path = chatType === 'general'
        ? `games/${gameFolder}/${jobId}/chats/general.json`
        : `games/${gameFolder}/${jobId}/chats/private/${chatId}.json`;
    return await githubUpdate(path, messages, sha);
};

const dbDeleteJob = async (placeId, jobId) => {
    if (DATABASE_METHOD === 'Firebase') {
        await fbDelete('rechat_jobs', `${placeId}_${jobId}`);
        await fbDelete('rechat_messages', `${placeId}_${jobId}_general`);
        return true;
    }
    return await githubDeleteFolder(`games/${placeId}/${jobId}`);
};

const loadMappings = async () => {
    if (mappingsLoaded) return;
    try {
        const { data: mappings } = await dbGetMappings();
        for (const [jobId, placeId] of Object.entries(mappings)) placeIdMap.set(jobId, placeId);
        mappingsLoaded = true;
        console.log(`[MAPPINGS] Loaded ${placeIdMap.size} JobId mappings`);
    } catch (error) { console.error('[MAPPINGS] Failed to load:', error.message); }
};

const registerPlaceId = async (jobId, placeId) => {
    if (placeIdMap.has(jobId)) return;
    placeIdMap.set(jobId, placeId);
    try {
        const result   = await dbGetMappings();
        const mappings = result.data;
        if (!mappings[jobId]) { mappings[jobId] = placeId; await dbSetMappings(mappings, result.sha); }
    } catch (error) { console.error('[REGISTER_PLACE]', error.message); }
};

const getGameInfo = async (placeId) => {
    const cacheKey = `game:${placeId}`;
    let gameInfo   = cache.get(placeId, cacheKey);
    if (!gameInfo) {
        try {
            const univRes  = await fetch(`https://apis.roblox.com/universes/v1/places/${placeId}/universe`);
            const univData = await univRes.json();
            const universeId = univData?.universeId;
            if (!universeId) throw new Error('No universeId');
            const gameRes  = await fetch(`https://games.roproxy.com/v1/games?universeIds=${universeId}`);
            const gameData = await gameRes.json();
            if (gameData.data && gameData.data[0]) gameInfo = { name: gameData.data[0].name, url: `https://www.roblox.com/games/${placeId}`, placeId };
            else gameInfo = { name: 'Unknown Game', url: `https://www.roblox.com/games/${placeId}`, placeId };
        } catch { gameInfo = { name: 'Unknown Game', url: `https://www.roblox.com/games/${placeId}`, placeId }; }
        cache.set(placeId, cacheKey, gameInfo);
    }
    return gameInfo;
};

const checkAntiSpam = (userId) => {
    const now      = Date.now();
    const lastTime = userMessageTimes.get(userId);
    if (lastTime && (now - lastTime) < MESSAGE_COOLDOWN) return { allowed: false, reason: 'Wait 2 seconds between messages' };
    const counts = userMessageCounts.get(userId) || { count: 0, reset: now + 60000 };
    if (now > counts.reset) { counts.count = 0; counts.reset = now + 60000; }
    if (counts.count >= MAX_MESSAGES_PER_MINUTE) return { allowed: false, reason: 'Too many messages! Max 15/min' };
    userMessageTimes.set(userId, now);
    counts.count++;
    userMessageCounts.set(userId, counts);
    return { allowed: true };
};

const ensurePlaceIdLoaded = async (jobId) => {
    let placeId = placeIdMap.get(jobId);
    if (!placeId && !mappingsLoaded) { await loadMappings(); placeId = placeIdMap.get(jobId); }
    return placeId || null;
};

const cleanupInactiveFolders = async () => {
    const now = Date.now();
    let deletedCount = 0;
    for (const [jobId, placeId] of placeIdMap.entries()) {
        try {
            const serverInfo = cache.get(jobId, 'server_info');
            if (!serverInfo) continue;
            if (!serverInfo.lastActivity || (now - serverInfo.lastActivity) > INACTIVE_THRESHOLD) {
                const deleted = await dbDeleteJob(placeId, jobId);
                if (deleted) { placeIdMap.delete(jobId); cache.clear(jobId); deletedCount++; console.log(`[CLEANUP] Deleted inactive job: ${placeId}/${jobId}`); }
            }
        } catch (e) { if (!e.message?.includes('403') && !e.message?.includes('rate limit')) console.error(`[CLEANUP] Error cleaning ${jobId}:`, e.message); }
    }
    if (deletedCount > 0) console.log(`[CLEANUP] Deleted ${deletedCount} inactive jobs`);
};

const handleRateLimitResponse = (res) => res.json({ success: false, message: "Rechat is currently experiencing instability, we'll be back soon!" });

wss.on('connection', (ws, req) => {
    const url   = new URL(req.url, `http://${req.headers.host}`);
    const jobId = url.searchParams.get('jobId');

    if (!jobId) { ws.close(1008, 'jobId required'); return; }

    if (!wsClients.has(jobId)) wsClients.set(jobId, new Set());
    wsClients.get(jobId).add(ws);
    ws.send(JSON.stringify({ type: 'connected', jobId }));

    const cleanup = () => {
        const clients = wsClients.get(jobId);
        if (clients) {
            clients.delete(ws);
            if (clients.size === 0) wsClients.delete(jobId);
        }
    };

    ws.on('message', async (raw) => {
        try {
            const body = JSON.parse(raw.toString());
            if (body.type !== 'send_message' && body.type !== 'send') return;

            const { userId, username, displayName, message, chatType = 'general', chatId } = body;

            if (!message || !userId || !username)
                return ws.send(JSON.stringify({ type: 'error', message: 'Missing required fields' }));

            if (message.length > MAX_MESSAGE_LENGTH)
                return ws.send(JSON.stringify({ type: 'error', message: `Max ${MAX_MESSAGE_LENGTH} chars` }));

            const placeId = await ensurePlaceIdLoaded(jobId);
            if (!placeId)
                return ws.send(JSON.stringify({ type: 'error', message: 'JobId not found. Call /init first.' }));

            if (chatType !== 'general' && !(chatType === 'private' && chatId))
                return ws.send(JSON.stringify({ type: 'error', message: 'Invalid chat type' }));

            const spamCheck = checkAntiSpam(userId);
            if (!spamCheck.allowed)
                return ws.send(JSON.stringify({ type: 'error', message: spamCheck.reason }));

            const filtered  = filterMessage(message);
            const cacheKey  = chatType === 'general' ? 'chats/general' : `chats/private/${chatId}`;
            let messages    = cache.get(jobId, cacheKey);
            let messagesSha = cache.get(jobId, `${cacheKey}:sha`);

            if (!messages) {
                const result = await dbGetMessages(placeId, jobId, chatType, chatId);
                messages     = result.data || [];
                messagesSha  = result.sha;
                cache.set(jobId, cacheKey, messages);
                cache.set(jobId, `${cacheKey}:sha`, messagesSha);
            }

            const now = Date.now();
            const newMessage = {
                id: crypto.randomBytes(8).toString('hex'),
                userId,
                username,
                displayName: displayName || username,
                message: filtered,
                timestamp: now
            };

            messages.push(newMessage);
            if (messages.length > 200) messages.splice(0, messages.length - 200);
            cache.set(jobId, cacheKey, messages);

            broadcastToJob(jobId, { type: 'new_message', chatType, chatId: chatId || null, message: newMessage });
            ws.send(JSON.stringify({ type: 'message_sent', message: 'Sent', messageData: newMessage }));

            const messagesSnapshot = [...messages];
            const shaSnapshot      = messagesSha;
            task.spawn(async () => {
                try {
                    const updateResult = await dbSetMessages(placeId, jobId, chatType, chatId, messagesSnapshot, shaSnapshot);
                    if (updateResult?.sha) cache.set(jobId, `${cacheKey}:sha`, updateResult.sha);
                } catch (error) {
                    console.error('[WS_SEND] Background save failed:', error.message);
                }
            });
        } catch (error) {
            console.error('[WS_MESSAGE]', error);
            ws.send(JSON.stringify({ type: 'error', message: 'Internal error' }));
        }
    });

    ws.on('close', cleanup);
    ws.on('error', cleanup);
});

app.use(async (req, res, next) => {
    if (MAINTENANCE_MODE) {
        if (req.path === '/api/v1/chat/messages') {
            const hwid     = generateHWID(req);
            const cacheKey = `maint_${req.query.jobId}_${hwid}`;
            let messages   = maintenanceMessagesCache.get(cacheKey);
            if (!messages) {
                const now = Date.now();
                messages  = [
                    { id: 'maint_1', userId: '3274233701', username: 'Rhyan571', displayName: 'Rhyan57', message: '<font color="#FF6B6B">Eae mano, o chat tá bugado aqui</font>', timestamp: now },
                    { id: 'maint_2', userId: '4142240577', username: 'PierreFSGamer1a', displayName: 'Loldog', message: '<font color="#4ECDC4">Aqui também cara, acho que tá em manutenção</font>', timestamp: now + 3000 },
                    { id: 'maint_3', userId: '3274233701', username: 'Rhyan571', displayName: 'Rhyan57', message: '<font color="#FF6B6B">Sério? Justo agora que eu tava jogando 😅</font>', timestamp: now + 6000 },
                    { id: 'maint_4', userId: '4142240577', username: 'PierreFSGamer1a', displayName: 'Loldog', message: '<font color="#4ECDC4">Pois é mano, deve tar arrumando alguma coisa</font>', timestamp: now + 9000 },
                    { id: 'maint_5', userId: '3274233701', username: 'Rhyan571', displayName: 'Rhyan57', message: '<font color="#FF6B6B">Quanto tempo tu acha que vai demorar?</font>', timestamp: now + 12000 },
                    { id: 'maint_6', userId: '4142240577', username: 'PierreFSGamer1a', displayName: 'Loldog', message: '<font color="#4ECDC4">Sei lá, mas geralmente é rápido. Vamo esperar 🤔</font>', timestamp: now + 15000 },
                    { id: 'maint_7', userId: '3274233701', username: 'Rhyan571', displayName: 'Rhyan57', message: '<font color="#FF6B6B">Blz, vou jogar enquanto isso então</font>', timestamp: now + 18000 },
                    { id: 'maint_8', userId: '4142240577', username: 'PierreFSGamer1a', displayName: 'Loldog', message: '<font color="#4ECDC4">Tmj! Qualquer coisa me chama 💜</font>', timestamp: now + 21000 }
                ];
                maintenanceMessagesCache.set(cacheKey, messages);
            }
            return res.json({ success: true, messages, total: 8 });
        }
        return res.json({ success: false, message: "🤔 Rechat isn't working right now, can it be back later?" });
    }
    setImmediate(() => { cleanupInactiveFolders().catch(err => console.error('[CLEANUP_MIDDLEWARE]', err)); });
    next();
});

app.get('/api/v1/chat/messages', async (req, res) => {
    try {
        const { jobId, chatType = 'general', chatId, limit = 50, after } = req.query;
        if (!jobId) return res.json({ success: false, message: 'JobId required' });

        const placeId = placeIdMap.get(jobId);
        if (!placeId) return res.json({ success: false, message: 'JobId not found. Please call /init first' });

        if (chatType !== 'general' && !(chatType === 'private' && chatId)) return res.json({ success: false, message: 'Invalid chat type' });

        const cacheKey = chatType === 'general' ? 'chats/general' : `chats/private/${chatId}`;
        let messages   = cache.get(jobId, cacheKey) || [];
        let filtered   = after ? messages.filter(msg => msg.timestamp > parseInt(after)) : messages;
        const recent   = filtered.slice(-parseInt(limit));

        res.json({ success: true, messages: recent, total: messages.length });
    } catch (error) { console.error('[GET_MESSAGES]', error); res.json({ success: false, message: 'Internal error' }); }
});

app.post('/api/v1/chat/init', async (req, res) => {
    try {
        const { userId, username, jobId, placeId, displayName } = req.body;
        if (!userId || !username || !jobId || !placeId) return res.json({ success: false, message: 'Missing required parameters' });

        console.log(`[INIT] Initializing for JobId: ${jobId}, PlaceId: ${placeId}`);

        placeIdMap.set(jobId, placeId);
        await registerPlaceId(jobId, placeId);

        const gameInfo = await getGameInfo(placeId);
        const now      = Date.now();

        const result = await dbGetServerInfo(placeId, jobId, {
            jobId, placeId, gameName: gameInfo.name, gameUrl: gameInfo.url,
            created: now, lastActivity: now, activeUsers: []
        });

        const serverInfo = result.data;
        if (!serverInfo.activeUsers) serverInfo.activeUsers = [];

        const userInfo      = { userId, username, displayName: displayName || username };
        const existingIndex = serverInfo.activeUsers.findIndex(u => u.userId === userId);
        if (existingIndex >= 0) serverInfo.activeUsers[existingIndex] = userInfo;
        else serverInfo.activeUsers.push(userInfo);
        serverInfo.lastActivity = now;

        cache.set(jobId, 'server_info', serverInfo);
        cache.set(jobId, 'server_info:sha', result.sha);

        const messagesResult = await dbGetMessages(placeId, jobId, 'general', null);
        cache.set(jobId, 'chats/general', messagesResult.data);
        cache.set(jobId, 'chats/general:sha', messagesResult.sha);

        task.spawn(async () => {
            try {
                const saveResult = await dbSetServerInfo(placeId, jobId, serverInfo, result.sha);
                if (saveResult?.sha) cache.set(jobId, 'server_info:sha', saveResult.sha);
            } catch (error) { console.error('[INIT] Background server info save failed:', error.message); }
        });

        console.log(`[INIT] Initialized successfully`);
        res.json({ success: true, gameInfo, message: 'Initialized' });
    } catch (error) {
        console.error('[INIT]', error);
        if (error.message?.includes('403') || error.message?.includes('rate limit')) return handleRateLimitResponse(res);
        res.json({ success: false, message: 'Internal error' });
    }
});

app.post('/api/v1/chat/send', async (req, res) => {
    try {
        const { jobId, userId, username, displayName, message, chatType = 'general', chatId } = req.body;

        if (!jobId || !message)              return res.json({ success: false, message: 'Missing required parameters (jobId, message)' });
        if (!userId || !username)            return res.json({ success: false, message: 'Missing userId and username' });
        if (message.length > MAX_MESSAGE_LENGTH) return res.json({ success: false, message: `Max ${MAX_MESSAGE_LENGTH} chars` });

        const placeId = await ensurePlaceIdLoaded(jobId);
        if (!placeId) return res.json({ success: false, message: 'JobId not found. Call /init first.' });

        if (chatType !== 'general' && !(chatType === 'private' && chatId)) return res.json({ success: false, message: 'Invalid chat type' });

        const spamCheck = checkAntiSpam(userId);
        if (!spamCheck.allowed) return res.json({ success: false, message: spamCheck.reason });

        const filtered  = filterMessage(message);
        const cacheKey  = chatType === 'general' ? 'chats/general' : `chats/private/${chatId}`;
        let messages    = cache.get(jobId, cacheKey);
        let messagesSha = cache.get(jobId, `${cacheKey}:sha`);

        if (!messages) {
            const result = await dbGetMessages(placeId, jobId, chatType, chatId);
            messages     = result.data || [];
            messagesSha  = result.sha;
            cache.set(jobId, cacheKey, messages);
            cache.set(jobId, `${cacheKey}:sha`, messagesSha);
        }

        const now        = Date.now();
        const newMessage = {
            id: crypto.randomBytes(8).toString('hex'),
            userId, username,
            displayName: displayName || username,
            message: filtered,
            timestamp: now
        };

        messages.push(newMessage);
        if (messages.length > 200) messages.splice(0, messages.length - 200);
        cache.set(jobId, cacheKey, messages);

        broadcastToJob(jobId, { type: 'new_message', chatType, chatId: chatId || null, message: newMessage });

        task.spawn(async () => {
            try {
                const updateResult = await dbSetMessages(placeId, jobId, chatType, chatId, messages, messagesSha);
                if (updateResult?.sha) cache.set(jobId, `${cacheKey}:sha`, updateResult.sha);
            } catch (error) { console.error('[SEND] Background save failed:', error.message); }
        });

        res.json({ success: true, message: 'Sent', messageData: newMessage });
    } catch (error) {
        console.error('[SEND] Critical error:', error);
        if (error.message?.includes('403') || error.message?.includes('rate limit')) return handleRateLimitResponse(res);
        res.json({ success: false, message: 'Internal error: ' + error.message });
    }
});

app.post('/api/v1/chat/private/create', async (req, res) => {
    try {
        const { userId, jobId, targetUserIds } = req.body;
        if (!userId || !jobId || !Array.isArray(targetUserIds) || targetUserIds.length === 0) return res.json({ success: false, message: 'Missing parameters' });
        if (targetUserIds.length > 3) return res.json({ success: false, message: 'Max 3 users' });

        const placeId = await ensurePlaceIdLoaded(jobId);
        if (!placeId) return res.json({ success: false, message: 'JobId not found' });

        const allUserIds = [userId, ...targetUserIds].sort();
        const chatId     = crypto.createHash('md5').update(allUserIds.join('-')).digest('hex');
        const cacheKey   = `chats/private/${chatId}`;

        let messages = cache.get(jobId, cacheKey);
        if (!messages) {
            const result = await dbGetMessages(placeId, jobId, 'private', chatId);
            messages     = result.data;
            cache.set(jobId, cacheKey, messages);
            cache.set(jobId, `${cacheKey}:sha`, result.sha);
        }

        res.json({ success: true, chatId, message: 'Private chat created' });
    } catch (error) { console.error('[CREATE_PRIVATE]', error); res.json({ success: false, message: 'Internal error' }); }
});

app.get('/api/v1/servers', async (req, res) => {
    try {
        const allServers = [];
        const now = Date.now();

        for (const [jobId, placeId] of placeIdMap.entries()) {
            try {
                let serverInfo = cache.get(jobId, 'server_info');
                if (!serverInfo) {
                    const result = await dbGetServerInfo(placeId, jobId, null);
                    if (!result || !result.data) continue;
                    serverInfo = result.data;
                    cache.set(jobId, 'server_info', serverInfo);
                }
                if (!serverInfo?.lastActivity) continue;
                if (now - serverInfo.lastActivity > 600000) continue;

                const messages = cache.get(jobId, 'chats/general') || [];
                const lastMessage = messages.length > 0 ? messages[messages.length - 1] : null;

                allServers.push({
                    jobId,
                    placeId,
                    gameName: serverInfo.gameName || 'Unknown Game',
                    gameUrl: serverInfo.gameUrl || '',
                    lastActivity: serverInfo.lastActivity,
                    activeUsers: serverInfo.activeUsers || [],
                    activeUsersCount: serverInfo.activeUsers ? serverInfo.activeUsers.length : 0,
                    lastMessage: lastMessage ? {
                        username: lastMessage.displayName || lastMessage.username,
                        message: lastMessage.message,
                        timestamp: lastMessage.timestamp
                    } : null
                });
            } catch {}
        }

        allServers.sort((a, b) => b.lastActivity - a.lastActivity);
        res.json({ success: true, servers: allServers, total: allServers.length });
    } catch (error) {
        console.error('[SERVERS]', error);
        res.json({ success: false, message: 'Internal error' });
    }
});

app.get('/servers', (req, res) => {
    res.send(`<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>ReChat — Live Servers</title>
<link href="https://fonts.googleapis.com/css2?family=Syne:wght@400;700;800&family=DM+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

  :root {
    --bg: #080a0f;
    --surface: #0e1118;
    --border: #1c2030;
    --accent: #ff3c5a;
    --accent2: #ff7a3c;
    --green: #3cffb0;
    --text: #e8eaf0;
    --muted: #5a6080;
    --card-bg: #0c0f1a;
  }

  html, body {
    background: var(--bg);
    color: var(--text);
    font-family: 'Syne', sans-serif;
    min-height: 100vh;
    overflow-x: hidden;
  }

  body::before {
    content: '';
    position: fixed;
    inset: 0;
    background:
      radial-gradient(ellipse 80% 50% at 20% -10%, rgba(255,60,90,0.08) 0%, transparent 60%),
      radial-gradient(ellipse 60% 40% at 80% 110%, rgba(60,255,176,0.05) 0%, transparent 60%);
    pointer-events: none;
    z-index: 0;
  }

  .noise {
    position: fixed;
    inset: 0;
    opacity: 0.025;
    background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 256 256' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='noise'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.9' numOctaves='4' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23noise)'/%3E%3C/svg%3E");
    pointer-events: none;
    z-index: 0;
  }

  header {
    position: relative;
    z-index: 10;
    padding: 48px 40px 32px;
    border-bottom: 1px solid var(--border);
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 20px;
  }

  .logo {
    display: flex;
    align-items: center;
    gap: 14px;
  }

  .logo-icon {
    width: 42px;
    height: 42px;
    background: linear-gradient(135deg, var(--accent), var(--accent2));
    border-radius: 12px;
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 20px;
    box-shadow: 0 0 24px rgba(255,60,90,0.4);
  }

  .logo h1 {
    font-size: 22px;
    font-weight: 800;
    letter-spacing: -0.5px;
  }

  .logo span {
    color: var(--accent);
  }

  .header-right {
    display: flex;
    align-items: center;
    gap: 16px;
  }

  .live-dot {
    display: flex;
    align-items: center;
    gap: 8px;
    font-family: 'DM Mono', monospace;
    font-size: 12px;
    color: var(--green);
    background: rgba(60,255,176,0.08);
    border: 1px solid rgba(60,255,176,0.2);
    padding: 6px 14px;
    border-radius: 100px;
  }

  .live-dot::before {
    content: '';
    width: 7px;
    height: 7px;
    background: var(--green);
    border-radius: 50%;
    animation: pulse 1.5s infinite;
    box-shadow: 0 0 8px var(--green);
  }

  @keyframes pulse {
    0%, 100% { opacity: 1; transform: scale(1); }
    50% { opacity: 0.5; transform: scale(0.8); }
  }

  .refresh-btn {
    background: transparent;
    border: 1px solid var(--border);
    color: var(--muted);
    padding: 7px 16px;
    border-radius: 8px;
    font-family: 'DM Mono', monospace;
    font-size: 12px;
    cursor: pointer;
    transition: all 0.2s;
  }

  .refresh-btn:hover {
    border-color: var(--accent);
    color: var(--accent);
  }

  main {
    position: relative;
    z-index: 10;
    padding: 40px;
    max-width: 1100px;
    margin: 0 auto;
  }

  .section-header {
    display: flex;
    align-items: baseline;
    gap: 12px;
    margin-bottom: 28px;
  }

  .section-title {
    font-size: 13px;
    font-weight: 700;
    letter-spacing: 3px;
    text-transform: uppercase;
    color: var(--muted);
  }

  .count-badge {
    font-family: 'DM Mono', monospace;
    font-size: 11px;
    color: var(--accent);
    background: rgba(255,60,90,0.1);
    border: 1px solid rgba(255,60,90,0.2);
    padding: 2px 8px;
    border-radius: 100px;
  }

  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fill, minmax(320px, 1fr));
    gap: 16px;
  }

  .card {
    background: var(--card-bg);
    border: 1px solid var(--border);
    border-radius: 16px;
    padding: 22px;
    display: flex;
    flex-direction: column;
    gap: 16px;
    transition: border-color 0.2s, transform 0.2s, box-shadow 0.2s;
    animation: fadeUp 0.4s ease both;
    position: relative;
    overflow: hidden;
  }

  .card::before {
    content: '';
    position: absolute;
    top: 0; left: 0; right: 0;
    height: 1px;
    background: linear-gradient(90deg, transparent, rgba(255,60,90,0.3), transparent);
    opacity: 0;
    transition: opacity 0.3s;
  }

  .card:hover {
    border-color: rgba(255,60,90,0.3);
    transform: translateY(-2px);
    box-shadow: 0 8px 32px rgba(0,0,0,0.4);
  }

  .card:hover::before { opacity: 1; }

  @keyframes fadeUp {
    from { opacity: 0; transform: translateY(16px); }
    to   { opacity: 1; transform: translateY(0); }
  }

  .card-top {
    display: flex;
    align-items: flex-start;
    justify-content: space-between;
    gap: 12px;
  }

  .game-info { flex: 1; min-width: 0; }

  .game-name {
    font-size: 15px;
    font-weight: 700;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
    margin-bottom: 4px;
  }

  .game-meta {
    font-family: 'DM Mono', monospace;
    font-size: 11px;
    color: var(--muted);
  }

  .users-pill {
    display: flex;
    align-items: center;
    gap: 5px;
    background: rgba(60,255,176,0.08);
    border: 1px solid rgba(60,255,176,0.15);
    color: var(--green);
    font-family: 'DM Mono', monospace;
    font-size: 11px;
    padding: 4px 10px;
    border-radius: 100px;
    white-space: nowrap;
    flex-shrink: 0;
  }

  .users-pill svg { width: 10px; height: 10px; }

  .last-message {
    background: rgba(255,255,255,0.03);
    border: 1px solid var(--border);
    border-radius: 10px;
    padding: 12px 14px;
    min-height: 52px;
    display: flex;
    flex-direction: column;
    gap: 4px;
  }

  .msg-author {
    font-size: 11px;
    font-weight: 700;
    color: var(--accent);
    font-family: 'DM Mono', monospace;
  }

  .msg-text {
    font-size: 13px;
    color: var(--text);
    opacity: 0.8;
    white-space: nowrap;
    overflow: hidden;
    text-overflow: ellipsis;
  }

  .msg-empty {
    font-size: 12px;
    color: var(--muted);
    font-style: italic;
    align-self: center;
    margin: auto;
  }

  .msg-time {
    font-family: 'DM Mono', monospace;
    font-size: 10px;
    color: var(--muted);
    margin-top: 2px;
  }

  .card-actions {
    display: flex;
    gap: 8px;
  }

  .btn-join {
    flex: 1;
    background: linear-gradient(135deg, var(--accent), var(--accent2));
    border: none;
    color: #fff;
    font-family: 'Syne', sans-serif;
    font-weight: 700;
    font-size: 13px;
    padding: 10px 20px;
    border-radius: 10px;
    cursor: pointer;
    transition: opacity 0.2s, transform 0.15s;
    text-decoration: none;
    text-align: center;
    display: flex;
    align-items: center;
    justify-content: center;
    gap: 6px;
    box-shadow: 0 4px 16px rgba(255,60,90,0.3);
  }

  .btn-join:hover { opacity: 0.88; transform: scale(0.98); }

  .btn-copy {
    background: transparent;
    border: 1px solid var(--border);
    color: var(--muted);
    font-family: 'DM Mono', monospace;
    font-size: 11px;
    padding: 10px 14px;
    border-radius: 10px;
    cursor: pointer;
    transition: all 0.2s;
    white-space: nowrap;
  }

  .btn-copy:hover { border-color: var(--text); color: var(--text); }
  .btn-copy.copied { border-color: var(--green); color: var(--green); }

  .empty-state {
    grid-column: 1 / -1;
    text-align: center;
    padding: 80px 20px;
    color: var(--muted);
  }

  .empty-state .icon { font-size: 48px; margin-bottom: 16px; display: block; }
  .empty-state p { font-size: 15px; }

  .loading-state {
    grid-column: 1 / -1;
    display: flex;
    flex-direction: column;
    align-items: center;
    gap: 16px;
    padding: 80px 20px;
    color: var(--muted);
  }

  .spinner {
    width: 32px;
    height: 32px;
    border: 2px solid var(--border);
    border-top-color: var(--accent);
    border-radius: 50%;
    animation: spin 0.8s linear infinite;
  }

  @keyframes spin { to { transform: rotate(360deg); } }

  footer {
    position: relative;
    z-index: 10;
    text-align: center;
    padding: 32px 40px;
    border-top: 1px solid var(--border);
    font-family: 'DM Mono', monospace;
    font-size: 11px;
    color: var(--muted);
  }

  footer a { color: var(--accent); text-decoration: none; }

  @media (max-width: 600px) {
    header { padding: 28px 20px 20px; flex-wrap: wrap; }
    main { padding: 24px 16px; }
    .grid { grid-template-columns: 1fr; }
  }
</style>
</head>
<body>
<div class="noise"></div>

<header>
  <div class="logo">
    <div class="logo-icon">💬</div>
    <h1>Re<span>Chat</span></h1>
  </div>
  <div class="header-right">
    <div class="live-dot" id="liveStatus">LIVE</div>
    <button class="refresh-btn" onclick="loadServers()">↻ refresh</button>
  </div>
</header>

<main>
  <div class="section-header">
    <span class="section-title">Active Servers</span>
    <span class="count-badge" id="countBadge">—</span>
  </div>
  <div class="grid" id="grid">
    <div class="loading-state">
      <div class="spinner"></div>
      <span>fetching servers...</span>
    </div>
  </div>
</main>

<footer>
  made by <a href="https://discord.gg/Pfmqq79q9Q" target="_blank">@rhyan57 & @loldog</a> · auto-refreshes every 15s
</footer>

<script>
  const API = '';

  function timeAgo(ts) {
    const diff = Math.floor((Date.now() - ts) / 1000);
    if (diff < 5)  return 'just now';
    if (diff < 60) return diff + 's ago';
    if (diff < 3600) return Math.floor(diff / 60) + 'm ago';
    return Math.floor(diff / 3600) + 'h ago';
  }

  function stripRichText(text) {
    return text.replace(/<[^>]+>/g, '').trim();
  }

  function copyJobId(jobId, btn) {
    navigator.clipboard.writeText(jobId).then(() => {
      btn.textContent = '✓ copied';
      btn.classList.add('copied');
      setTimeout(() => {
        btn.textContent = 'copy id';
        btn.classList.remove('copied');
      }, 1500);
    });
  }

  function buildCard(server, index) {
    const joinUrl = server.placeId ? 'https://externalrobloxjoiner.vercel.app/join?placeId=' + server.placeId : null;
    const lastMsg = server.lastMessage;
    const delay   = (index * 60) + 'ms';

    const msgHtml = lastMsg
      ? \`<span class="msg-author">\${escHtml(lastMsg.username)}</span>
         <span class="msg-text">\${escHtml(stripRichText(lastMsg.message))}</span>
         <span class="msg-time">\${timeAgo(lastMsg.timestamp)}</span>\`
      : \`<span class="msg-empty">no messages yet</span>\`;

    return \`
      <div class="card" style="animation-delay:\${delay}">
        <div class="card-top">
          <div class="game-info">
            <div class="game-name">\${escHtml(server.gameName)}</div>
            <div class="game-meta">active \${timeAgo(server.lastActivity)}</div>
          </div>
          <div class="users-pill">
            <svg viewBox="0 0 24 24" fill="currentColor"><path d="M16 11c1.66 0 2.99-1.34 2.99-3S17.66 5 16 5c-1.66 0-3 1.34-3 3s1.34 3 3 3zm-8 0c1.66 0 2.99-1.34 2.99-3S9.66 5 8 5C6.34 5 5 6.34 5 8s1.34 3 3 3zm0 2c-2.33 0-7 1.17-7 3.5V19h14v-2.5c0-2.33-4.67-3.5-7-3.5zm8 0c-.29 0-.62.02-.97.05 1.16.84 1.97 1.97 1.97 3.45V19h6v-2.5c0-2.33-4.67-3.5-7-3.5z"/></svg>
            \${server.activeUsersCount}
          </div>
        </div>
        <div class="last-message">\${msgHtml}</div>
        <div class="card-actions">
          \${joinUrl
            ? \`<a class="btn-join" href="\${joinUrl}" target="_blank">▶ Join Game</a>\`
            : \`<button class="btn-join" disabled style="opacity:0.4;cursor:not-allowed">▶ Join Game</button>\`
          }
          <button class="btn-copy" onclick="copyJobId('\${escHtml(server.jobId)}', this)">copy id</button>
        </div>
      </div>
    \`;
  }

  function escHtml(str) {
    return String(str)
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  async function loadServers() {
    const grid  = document.getElementById('grid');
    const badge = document.getElementById('countBadge');

    try {
      const res  = await fetch(API + '/api/v1/servers');
      const data = await res.json();

      if (!data.success || data.servers.length === 0) {
        grid.innerHTML = \`
          <div class="empty-state">
            <span class="icon">🌙</span>
            <p>No active servers right now.</p>
          </div>\`;
        badge.textContent = '0';
        return;
      }

      badge.textContent = data.total;
      grid.innerHTML = data.servers.map((s, i) => buildCard(s, i)).join('');
    } catch (e) {
      grid.innerHTML = \`
        <div class="empty-state">
          <span class="icon">⚠️</span>
          <p>Failed to load servers.</p>
        </div>\`;
      badge.textContent = '!';
    }
  }

  loadServers();
  setInterval(loadServers, 15000);
</script>
</body>
</html>`);
});

app.get('/api/v1/server/active/latest', async (req, res) => {
    try {
        const { excludeUserId } = req.query;
        const allServers = [];

        for (const [jobId, placeId] of placeIdMap.entries()) {
            try {
                let serverInfo = cache.get(jobId, 'server_info');
                if (!serverInfo) {
                    const result = await dbGetServerInfo(placeId, jobId, null);
                    if (!result || !result.data) continue;
                    serverInfo = result.data;
                    cache.set(jobId, 'server_info', serverInfo);
                }
                if (!serverInfo?.lastActivity) continue;
                if (Date.now() - serverInfo.lastActivity > 600000) continue;
                if (excludeUserId && serverInfo.activeUsers?.some(u => u.userId === excludeUserId)) continue;
                allServers.push({
                    jobId, placeId,
                    gameName: serverInfo.gameName || 'Unknown Game',
                    gameUrl: serverInfo.gameUrl || '',
                    lastActivity: serverInfo.lastActivity,
                    activeUsers: serverInfo.activeUsers ? serverInfo.activeUsers.length : 0
                });
            } catch {}
        }

        if (allServers.length === 0) return res.json({ success: false, message: 'No active servers found' });
        allServers.sort((a, b) => b.lastActivity - a.lastActivity);
        res.json({ success: true, server: allServers[0] });
    } catch (error) {
        console.error('[LATEST_ACTIVE]', error);
        if (error.message?.includes('403') || error.message?.includes('rate limit')) return handleRateLimitResponse(res);
        res.json({ success: false, message: 'Internal error: ' + error.message });
    }
});

app.get('/api/v1/chat/users', async (req, res) => {
    try {
        const { jobId } = req.query;
        if (!jobId) return res.json({ success: false, message: 'JobId required' });

        let placeId = placeIdMap.get(jobId);
        if (!placeId) { await loadMappings(); placeId = placeIdMap.get(jobId); }
        if (!placeId) return res.json({ success: false, message: 'JobId not found' });

        let serverInfo = cache.get(jobId, 'server_info');
        if (!serverInfo) {
            try {
                const result = await dbGetServerInfo(placeId, jobId, { activeUsers: [] });
                serverInfo   = result.data;
                cache.set(jobId, 'server_info', serverInfo);
            } catch { serverInfo = { activeUsers: [] }; }
        }

        res.json({ success: true, users: serverInfo.activeUsers || [], total: (serverInfo.activeUsers || []).length });
    } catch (error) { console.error('[GET_USERS]', error); res.json({ success: false, message: 'Internal error' }); }
});

app.get('/api/v1/stats', (req, res) => {
    res.json({
        success: true,
        database: DATABASE_METHOD,
        ws_connections: [...wsClients.entries()].reduce((acc, [, s]) => acc + s.size, 0),
        cache: { jobs: cache.getStats(), totalJobs: cache.jobCaches.size },
        mappings: { jobIds: placeIdMap.size }
    });
});

app.use((err, req, res, next) => { console.error('[ERROR]', err); res.status(500).json({ success: false, message: 'Internal error' }); });
app.use((req, res) => res.status(404).json({ success: false, message: 'Not found' }));

setInterval(async () => { try { await cleanupInactiveFolders(); } catch (error) { console.error('[CLEANUP_INTERVAL]', error); } }, 15 * 60 * 1000);

const PORT = process.env.PORT || 3000;
server.listen(PORT, async () => {
    console.log(`🚀 ReChat API running on port ${PORT}`);
    console.log(`📦 Database: ${DATABASE_METHOD}`);
    console.log(`🔌 WebSocket: enabled`);
    if (DATABASE_METHOD === 'Github') console.log(`🔑 GitHub tokens: ${GITHUB_TOKENS.length}`);
    await loadMappings();
});
