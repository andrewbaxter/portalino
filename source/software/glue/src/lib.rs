use {
    loga::{
        ea,
        DebugDisplay,
        ResultContext,
    },
    std::process::{
        Command,
        Stdio,
    },
};

pub fn run(command: &mut Command) -> Result<std::process::Output, loga::Error> {
    return Ok((|| -> Result<std::process::Output, loga::Error> {
        command.stdout(Stdio::piped());
        command.stderr(Stdio::piped());
        let p = command.spawn()?;
        let res = p.wait_with_output()?;
        if !res.status.success() {
            return Err(loga::err_with("Command exited with error code", ea!(output = res.dbg_str())));
        }
        return Ok(res);
    })().context_with("Error executing command", ea!(command = command.dbg_str()))?);
}
