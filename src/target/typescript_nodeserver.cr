require "./target"

class TypeScriptServerTarget < Target
  def gen
    @io << <<-END
import http from "http";
import crypto from "crypto";
import os from "os";
import url from "url";
import moment from "moment";
import r from "../rethinkdb";

let captureError: (e: Error, req?: http.IncomingMessage, extra?: any) => void = () => {};
export function setCaptureErrorFn(fn: (e: Error, req?: http.IncomingMessage, extra?: any) => void) {
    captureError = fn;
}

function failedCheckTypeError(descr: string) {
    setTimeout(() => captureError(new Error("Invalid Type at '" + descr + "'")), 1);
}


END

    @io << "export const fn: {\n"
    @ast.operations.each do |op|
      args = ["ctx: Context"] + op.args.map { |arg| "#{arg.name}: #{arg.type.typescript_native_type}" }
      @io << "    " << op.pretty_name << ": (#{args.join(", ")}) => Promise<#{op.return_type.typescript_native_type}>;\n"
    end
    @io << "} = {\n"
    @ast.operations.each do |op|
      @io << "    " << op.pretty_name << ": () => { throw \"not implemented\"; },\n"
    end
    @io << "};\n\n"

    @ast.struct_types.each do |t|
      @io << t.typescript_definition
      @io << "\n\n"
    end

    @ast.enum_types.each do |t|
      @io << t.typescript_definition
      @io << "\n\n"
    end

    @io << "const fnExec: {[name: string]: (ctx: Context, args: any) => Promise<any>} = {\n"
    @ast.operations.each do |op|
      @io << "    " << op.pretty_name << ": async (ctx: Context, args: any) => {\n"
      op.args.each do |arg|
        @io << ident ident arg.type.typescript_check_decoded("args.#{arg.name}", "\"#{op.pretty_name}.args.#{arg.name}\"")
        @io << ident ident "const #{arg.name} = #{arg.type.typescript_decode("args.#{arg.name}")};"
        @io << "\n"
      end
      @io << ident ident "const ret = await fn.#{op.pretty_name}(#{(["ctx"] + op.args.map(&.name)).join(", ")});\n"
      @io << ident ident "return " + op.return_type.typescript_encode("ret") + ";"
      @io << "\n"
      @io << "  },\n"
    end
    @io << "};\n\n"

    @io << "const clearForLogging: {[name: string]: (call: DBApiCall) => void} = {\n"
    @ast.operations.each do |op|
      cmds_args = String.build { |io| emit_clear_for_logging(io, op, "call.args") }

      if cmds_args != ""
        @io << "    " << op.pretty_name << ": async (call: DBApiCall) => {\n"
        @io << ident ident cmds_args
        @io << ident "},\n"
      end
    end
    @io << "};\n\n"

    @io << "export const err = {\n"
    @ast.errors.each do |error|
      @io << ident "#{error}: (message: string = \"\") => { throw {type: #{error.inspect}, message}; },\n"
    end
    @io << "};\n\n"

    @io << <<-END
//////////////////////////////////////////////////////

const httpHandlers: {
    [signature: string]: (body: string, res: http.ServerResponse, req: http.IncomingMessage) => void
} = {}

export function handleHttp(method: "GET" | "POST" | "PUT" | "DELETE", path: string, func: (body: string, res: http.ServerResponse, req: http.IncomingMessage) => void) {
    httpHandlers[method + path] = func;
}

export function handleHttpPrefix(method: "GET" | "POST" | "PUT" | "DELETE", path: string, func: (body: string, res: http.ServerResponse, req: http.IncomingMessage) => void) {
    httpHandlers["prefix " + method + path] = func;
}

export interface Context {
    device: DBDevice;
    startTime: Date;
    staging: boolean;
}

function sleep(ms: number) {
    return new Promise<void>(resolve => setTimeout(resolve, ms));
}

export function start(port: number) {
    const server = http.createServer((req, res) => {
        req.on("error", (err) => {
            console.error(err);
        });

        res.on("error", (err) => {
            console.error(err);
        });

        res.setHeader("Access-Control-Allow-Origin", "*");
        res.setHeader("Access-Control-Allow-Methods", "PUT, POST, GET, OPTIONS");
        res.setHeader("Access-Control-Allow-Headers", "Content-Type");
        res.setHeader("Access-Control-Max-Age", "86400");
        res.setHeader("Content-Type", "application/json");

        let body = "";
        req.on("data", (chunk: any) => body += chunk.toString());
        req.on("end", () => {
            if (req.method === "OPTIONS") {
                res.writeHead(200);
                res.end();
                return;
            }
            const ip = req.headers["x-real-ip"] as string || "";
            const signature = req.method! + url.parse(req.url || "").pathname;
            if (httpHandlers[signature]) {
                console.log(`${moment().format("YYYY-MM-DD HH:mm:ss")} http ${signature}`);
                httpHandlers[signature](body, res, req);
                return;
            }
            for (let target in httpHandlers) {
                if (("prefix " + signature).startsWith(target)) {
                    console.log(`${moment().format("YYYY-MM-DD HH:mm:ss")} http ${target}`);
                    httpHandlers[target](body, res, req);
                    return;
                }
            }

            switch (req.method) {
                case "HEAD": {
                    res.writeHead(200);
                    res.end();
                    break;
                }
                case "GET": {
                    r.expr(`{"ok": true}`).then(result => {
                        res.writeHead(200);
                        res.write(result);
                        res.end();
                    });
                    break;
                }
                case "POST": {
                    (async () => {
                        const request = JSON.parse(body);
                        request.device.ip = ip;
                        const context: Context = {
                            device: request.device,
                            startTime: new Date,
                            staging: request.staging || false
                        };
                        const startTime = process.hrtime();

                        const {id, ...deviceInfo} = context.device;

                        if (!context.device.id || await r.table("devices").get(context.device.id).eq(null)) {
                            context.device.id = crypto.randomBytes(20).toString("hex");

                            await r.table("devices").insert({
                                id: context.device.id,
                                date: r.now(),
                                ...deviceInfo
                            });
                        } else {
                            r.table("devices").get(context.device.id).update(deviceInfo).run();
                        }

                        const executionId = crypto.randomBytes(20).toString("hex");

                        let call: DBApiCall = {
                            id: `${request.id}-${context.device.id}`,
                            name: request.name,
                            args: JSON.parse(JSON.stringify(request.args)),
                            executionId: executionId,
                            running: true,
                            device: context.device,
                            date: context.startTime,
                            duration: 0,
                            host: os.hostname(),
                            ok: true,
                            result: null as any,
                            error: null as {type: string, message: string}|null
                        };

                        if (clearForLogging[call.name])
                            clearForLogging[call.name](call);

                        async function tryLock(): Promise<boolean> {
                            const priorCall = await r.table("api_calls").get(call.id);
                            if (priorCall === null) {
                                const res = await r.table("api_calls").insert(call);
                                return res.inserted > 0 ? true : await tryLock();
                            }
                            call = priorCall;
                            if (!call.running) {
                                return true;
                            }
                            if (call.executionId === executionId) {
                                return true;
                            }
                            return false;
                        }

                        for (let i = 0; i < 600; ++i) {
                            if (await tryLock()) break;
                            await sleep(100);
                        }

                        if (call.running) {
                            if (call.executionId !== executionId) {
                                call.ok = false;
                                call.error = {
                                    type: "Fatal",
                                    message: "CallExecutionTimeout: Timeout while waiting for execution somewhere else (is the original container that received this request dead?)"
                                };
                            } else {
                                try {
                                    call.result = await fnExec[request.name](context, request.args);
                                } catch (err) {
                                    console.error(err);
                                    call.ok = false;
                                    if (err.type) {
                                        call.error = {
                                            type: err.type,
                                            message: err.message
                                        };
                                    } else {
                                        call.error = {
                                            type: "Fatal",
                                            message: err.toString()
                                        };
                                    }
                                }
                                call.running = false;
                                const deltaTime = process.hrtime(startTime);
                                call.duration = deltaTime[0] + deltaTime[1] * 1e-9;
                                if (call.error && call.error.type === "Fatal") {
                                    setTimeout(() => captureError(new Error(call.error!.type + ": " + call.error!.message), req, {
                                        call
                                    }), 1);
                                }
                            }

                            r.table("api_calls").get(call.id).update(call).run();
                        }

                        const response = {
                            id: call.id,
                            ok: call.ok,
                            executed: call.executionId === executionId,
                            deviceId: call.device.id,
                            startTime: call.date,
                            duration: call.duration,
                            host: call.host,
                            result: call.result,
                            error: call.error
                        };

                        res.writeHead(200);
                        res.write(JSON.stringify(response));
                        res.end();

                        console.log(
                            `${moment().format("YYYY-MM-DD HH:mm:ss")} ` +
                            `${call.id} [${call.duration.toFixed(6)}s] ` +
                            `${call.name}() -> ${call.ok ? "OK" : call.error ? call.error.type : "???"}`
                        );
                    })().catch(err => {
                        console.error(err);
                        res.writeHead(500);
                        res.end();
                    });
                    break;
                }
                default: {
                    res.writeHead(500);
                    res.end();
                }
            }
        });
    });

    if ((server as any).keepAliveTimeout)
        (server as any).keepAliveTimeout = 0;

    server.listen(port, () => {
        console.log(`Listening on ${server.address().address}:${server.address().port}`);
    });
}

fn.ping = async (ctx: Context) => "pong";

fn.setPushToken = async (ctx: Context, token: string) => {
    await r.table("devices").get(ctx.device.id).update({push: token});
};

END
  end

  @i = 0

  def emit_clear_for_logging(io : IO, t : AST::Type | AST::Operation | AST::Field, path : String)
    case t
    when AST::Operation
      t.args.each do |field|
        emit_clear_for_logging(io, field, "#{path}.#{field.name}")
      end
    when AST::StructType
      t.fields.each do |field|
        emit_clear_for_logging(io, field, "#{path}.#{field.name}")
      end
    when AST::Field
      if t.secret
        io << "#{path} = \"<secret>\";\n"
      else
        emit_clear_for_logging(io, t.type, path)
      end
    when AST::TypeReference
      emit_clear_for_logging(io, t.type, path)
    when AST::OptionalType
      cmd = String.build { |io| emit_clear_for_logging(io, t.base, path) }
      if cmd != ""
        io << "if (#{path}) {\n" << ident(cmd) << "}\n"
      end
    when AST::ArrayType
      var = ('i' + @i).to_s
      @i += 1
      cmd = String.build { |io| emit_clear_for_logging(io, t.base, "#{path}[#{var}]") }
      @i -= 1
      if cmd != ""
        io << "for (let #{var} = 0; #{var} < #{path}.length; ++#{var}) {\n" << ident(cmd) << "}\n"
      end
    when AST::BytesPrimitiveType
      io << "#{path} = `<${#{path}.length} bytes>`;\n"
    end
  end
end

Target.register(TypeScriptServerTarget, target_name: "typescript_nodeserver")
