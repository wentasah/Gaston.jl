## Copyright (c) 2013 Miguel Bazdresch
##
## This file is distributed under the 2-clause BSD License.

# Asynchronously reads the IO and buffers the read content. When end
# marker (GastonDone) is found in the content, sends everything
# between start (GastonBegin) and end markers to the returned channel.
# In case of timeout sends :timeout, in case of end of file, sends
# :eof.
function async_reader(io::IO, timeout_sec)::Channel
    ch = Channel(1)
    task = @async begin
        reader_task = current_task()
        function timeout_cb(timer)
            put!(ch, :timeout)
            Base.throwto(reader_task, InterruptException())
        end

        buf = ""
        while (match_done = findfirst("GastonDone\n", buf)) == nothing
            timeout = Timer(timeout_cb, timeout_sec)
            data = String(readavailable(io))
            if data == ""; put!(ch, :eof); return; end
            timeout_sec > 0 && close(timeout) # Cancel the timeout
            buf *= data
        end
        match_begin = findfirst("GastonBegin\n", buf)
        start = (match_begin != nothing) ? last(match_begin)+1 : 1
        put!(ch, buf[start:first(match_done)-1])
    end
    bind(ch, task)
    return ch
end

# llplot() is our workhorse plotting function
function llplot()
    global gnuplot_state
    global gaston_config

    # select current figure
    c = findfigure(gnuplot_state.current)
    if c == 0
        println("No current figure")
        return
    end
    fig = gnuplot_state.figs[c]
    config = fig.conf

    # if figure has no data, stop here
    if isempty(fig.isempty)
        return
    end

    # Reset gnuplot settable options.
    gnuplot_send("\nreset\n")

    # Start reading gnuplot's stdout in "background"
    ch_out = async_reader(gstdout, 5)

    # In order to capture all output produced by our plotting commands
    # (error messages and figure text in case of text terminals), we
    # send "marks" to the stdout and stderr streams before the first
    # and after the last command. Everything between these marks will
    # be returned by our async_readers.
    gnuplot_send("set print \"-\"") # Redirect print to stdout
    gnuplot_send("print \"GastonBegin\"")
    gnuplot_send("printerr \"GastonBegin\"")

    # Build terminal setup string and send it to gnuplot
    gnuplot_send(termstring())

    # Datafile filename. This is where we store the coordinates to plot.
    # This file is then read by gnuplot to do the actual plotting. One file
    # per figure handle is used; this avoids polutting /tmp with too many files.
    filename = joinpath(tempdir(),
                        "gaston-$(gaston_config.tmpprefix)-$(fig.handle)")
    f = open(filename,"w")

    # Send appropriate coordinates and data to gnuplot, depending on
    # whether we are doing 2-d, 3-d or image plots.

    # 2-d plot: Z is empty or plostyle is {,rgb}image
    if isempty(fig.curves[1].Z) ||
        fig.curves[1].conf.plotstyle == "image" ||
        fig.curves[1].conf.plotstyle == "rgbimage"
        # create data file
        for i in fig.curves
            ps = i.conf.plotstyle
            if ps == "errorbars" || ps == "errorlines"
                if isempty(i.E.yhigh)
                    # ydelta (single error coordinate)
                    writedlm(f,[i.x i.y i.E.ylow],' ')
                else
                    # ylow, yhigh (double error coordinate)
                    writedlm(f,[i.x i.y i.E.ylow i.E.yhigh],' ')
                end
            elseif ps == "financebars"
                # data is written to tmparr, which is then written to disk
                tmparr = zeros(length(i.x),5)
                # output matrix
                for col = 1:length(i.x)
                    tmparr[col,1] = i.x[col]
                    tmparr[col,2] = i.F.open[col]
                    tmparr[col,3] = i.F.low[col]
                    tmparr[col,4] = i.F.high[col]
                    tmparr[col,5] = i.F.close[col]
                end
                writedlm(f,tmparr,' ')
            elseif ps == "image"
                # data is written to tmparr, which is then written to disk
                tmparr = zeros(length(i.x)*length(i.y),3)
                tmparr_row_index = 1  # index into tmparr row
                # output matrix
                for row = 1:length(i.y)
                    x = length(i.x)
                    for col = 1:length(i.x)
                        tmparr[tmparr_row_index,1] = i.x[col]
                        tmparr[tmparr_row_index,2] = i.y[row]
                        tmparr[tmparr_row_index,3] = i.Z[row,col]
                        tmparr_row_index = tmparr_row_index+1
                        x = x-1
                    end
                end
                writedlm(f,tmparr,' ')
            elseif ps == "rgbimage"
                # data is written to tmparr, which is then written to disk
                tmparr = zeros(length(i.x)*length(i.y), 5)
                tmparr_row_index = 1
                # output matrix
                for col = 1:length(i.x)
                    y = length(i.y)
                    for row = 1:length(i.y)
                        tmparr[tmparr_row_index,1] = i.x[col]
                        tmparr[tmparr_row_index,2] = i.y[row]
                        tmparr[tmparr_row_index,3] = i.Z[y,col,1]
                        tmparr[tmparr_row_index,4] = i.Z[y,col,2]
                        tmparr[tmparr_row_index,5] = i.Z[y,col,3]
                        tmparr_row_index = tmparr_row_index+1
                        y = y-1
                    end
                end
                writedlm(f,tmparr,' ')
            else
                writedlm(f,[i.x i.y],' ')
            end
            write(f,"\n\n")
        end
        close(f)
        # send figure configuration to gnuplot
        gnuplot_send_fig_config(config)
        # Send user command to gnuplot
        !isempty(fig.gpcom) && gnuplot_send(fig.gpcom)
        # send plot command to gnuplot
        gnuplot_send(linestr(fig.curves, "plot", filename))

    # 3-d plot: Z is not empty and plotstyle is not {,rgb}image
    elseif !isempty(fig.curves[1].Z) &&
            fig.curves[1].conf.plotstyle != "image" &&
            fig.curves[1].conf.plotstyle != "rgbimage"
        # create data file
        for i in fig.curves
            # data is written to tmparr, which is then written to disk
            tmparr = zeros(1, 3)
            tmparr_row_index = 1
            for row in 1:length(i.x)
                for col in 1:length(i.y)
                    tmparr[1,1] = i.x[row]
                    tmparr[1,2] = i.y[col]
                    tmparr[1,3] = i.Z[row,col]
                    writedlm(f,tmparr,' ')
                end
                write(f,"\n")
            end
            write(f,"\n\n")
        end
        close(f)
        # send figure configuration to gnuplot
        gnuplot_send_fig_config(config)
        # Send user command to gnuplot
        !isempty(fig.gpcom) && gnuplot_send(fig.gpcom)
        # send command to gnuplot
        gnuplot_send(linestr(fig.curves, "splot",filename))
    end

    # Make sure gnuplot is done; if terminal is text, read data
    # reset error handling
    err = ""
    gnuplot_state.gp_lasterror = err
    gnuplot_state.gp_error = false

    gnuplot_send("print \"GastonDone\"")
    gnuplot_send("printerr \"GastonDone\"")

    out = take!(ch_out)

    ch_err = async_reader(gstderr, 1)
    err = take!(ch_err)

    out === :timeout && error("Gnuplot is taking too long to respond.")
    out === :eof     && error("Gnuplot crashed")

    # We don't care about stderr timeouts.
    err === :timeout && (err = "")
    err === :eof     && (err = "")

    # check for errors while plotting
    if err != ""
        gnuplot_state.gp_lasterror = err
        gnuplot_state.gp_error = true
        @warn("Gnuplot returned an error message:\n  $err)")
    end

    # if there was no error and text terminal, read all data from stdout
    if err == ""
        if (gaston_config.terminal ∈ term_text)
            first = gaston_config.terminal == "dumb" && out[1] == '\f' ? 2 : 1
            fig.svg = out[first:end]
        end
    end

    return nothing

end
