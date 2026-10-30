module JFBuild
  class Console
    COLORS = { 'title' => '1;36', 'running' => 36, 'ready' => 32, 'success' => 32, 'skipped' => 33, 'failed' => 31, 'error' => 31 }.freeze
    def initialize(output = $stdout, input = $stdin, color: nil)
      @output, @input = output, input
      @color = color.nil? ? (output.respond_to?(:tty?) && output.tty? && !ENV.key?('NO_COLOR')) : color
    end

    def paint(text, state)
      text = text.to_s.gsub(/[\r\n]+/, ' ')
      @color ? "\e[#{COLORS.fetch(state, 0)}m#{text}\e[0m" : text
    end

    def flow(entries, prefix: '', compact: false)
      parts = entries.map do |entry|
        text = entry.fetch('label')
        reason = entry['reason'].to_s.gsub(/[\r\n]+/, ' ')
        if entry['status'] == 'skipped'
          text += if entry['name'] == 'dingtalk'
                    "（跳过#{reason.empty? ? '' : '，' + reason}）"
                  else
                    compact ? '（跳过）' : "（#{reason}，跳过该步骤）"
                  end
        end
        text += compact ? '（缺少配置）' : "（#{reason}，此流程无法开始）" if entry['status'] == 'error'
        text += '（成功）' if entry['status'] == 'success'
        text += compact ? '（失败）' : "（失败#{reason.empty? ? '' : '：' + reason}）" if entry['status'] == 'failed'
        paint(text, entry['status'])
      end
      @output.puts(prefix + parts.join(' → '))
    end

    def option(title, entries)
      line(title, 'title')
      flow(entries, prefix: '   ', compact: true)
      line('')
    end

    def details(entries)
      entries.each do |entry|
        next if entry['status'] == 'ready' || entry['status'] == 'success' || entry['reason'].to_s.empty?
        line("  #{entry.fetch('label')}：#{entry['reason']}", entry['status'])
      end
      line('')
    end

    def line(text, state = nil)
      @output.puts(state ? paint(text, state) : text)
    end

    def progress(label)
      if @progress
        state = @progress
        previous = state[:detail]
        state[:detail] = label
        begin
          return yield(->(detail) { state[:detail] = detail })
        ensure
          state[:detail] = previous
        end
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      state = { detail: nil }
      @progress = state
      terminal = @output.respond_to?(:tty?) && @output.tty? && ENV['TERM'] != 'dumb'
      render = lambda do |finished = nil|
        seconds = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to_i
        duration = format('%02d:%02d', seconds / 60, seconds % 60)
        detail = state[:detail].to_s
        if finished
          text = "#{label}#{finished == 'success' ? '完成' : '失败'}（用时 #{duration}）"
        else
          text = "正在#{label}#{detail.empty? || detail == label ? '' : '：' + detail}（已用 #{duration}）"
        end
        text = paint(text, finished || 'running')
        terminal ? @output.print("\r\e[2K#{text}#{finished ? "\n" : ''}") : @output.puts(text)
        @output.flush
      end
      completed = false
      updater = nil
      begin
        render.call
        updater = Thread.new do
          loop do
            sleep(terminal ? 1 : 10)
            render.call
          end
        end
        value = yield(->(detail) { state[:detail] = detail })
        completed = true
        value
      ensure
        updater.kill.join if updater
        @progress = nil
        render.call(completed ? 'success' : 'failed')
      end
    end

    def choose(prompt, allowed)
      loop do
        @output.print(prompt)
        @output.flush
        value = @input.gets
        raise Error, '未收到选择，已退出。' unless value
        value = value.strip
        return nil if value == '0'
        return value if allowed.include?(value)
        line("请输入 #{allowed.join('、')}，或输入 0 退出。", 'error')
      end
    end

    def description(value)
      return value.strip unless value.to_s.strip.empty?
      loop do
        @output.print('请输入本次更新内容：')
        @output.flush
        value = @input.gets
        raise Error, '缺少更新内容，可使用 --desc="更新说明"。' unless value
        return value.strip unless value.strip.empty?
        line('更新内容不能为空。', 'error')
      end
    end
  end
end
