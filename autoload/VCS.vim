augroup VCS
augroup end

function! VCS#SplitHGDiff()
  diffoff!
  let l:filetype = &l:filetype
  leftabove vert new
  r !hg cat #
  normal! ggdd
  setlocal readonly nomodifiable
  set buftype=nofile bufhidden=wipe
  let l:diff_buffer = bufnr('%')

  if strlen(l:filetype)
    exe 'setfiletype ' . l:filetype
  endif
  diffthis

  wincmd p


  diffthis
  if strlen(l:filetype)
    exe 'setfiletype ' . l:filetype
  endif

  " set up an autocmd so that when the current buffer is wiped out, the diff
  " buffer is also wiped out
  " NOTE: this causes versions of vim up to and including 7.3 to crash, so we
  " are leaving it off for now
  if 0 && v:version >= 704
    augroup VCS
    exe printf('autocmd BufHidden <buffer> silent! bwipeout %d', l:diff_buffer)
    augroup end
  endif

endfunction

function! VCS#GitDiff(gitref)
  " if an existing diff exists, wipe it out first
  if exists('b:before_git_diff')
    let l:diff_buf = b:before_git_diff[3]
    silent! exe 'bwipeout' l:diff_buf
  endif

  let l:filename = expand('%')
  let l:filetype = &l:filetype
  let l:before_git_diff = [ &l:foldmethod, &l:foldcolumn, &l:wrap ]
  let b:before_git_diff = l:before_git_diff
  let l:orig_buffer = bufnr('%')
  let l:orig_window = winnr()
  let l:split = 0
  diffthis
  try
    " create the new window
    aboveleft vertical keepalt new
    let l:split = bufnr('%')
    let &l:filetype = l:filetype

    " if the target is _merge_base_, we need to find out what that revision is
    if a:gitref == '_merge_base_'
      let l:target = strpart(system('git merge-base HEAD Dev'), 0, 7)
    else
      let l:target = a:gitref
    endif

    " paste the new file contents
    keepalt silent execute 'read !git show ' . l:target . ':' . l:filename
    keepalt normal! ggdd
    setlocal readonly
    setlocal buftype=nofile
    setlocal readonly
    diffthis

    " set up mapping so that \d toggles the iwhite diff option
    nnoremap \d :exe 'setlocal diffopt' . ((&g:diffopt =~ 'iwhite') ? '-' : '+') . '=iwhite diffopt?'<CR>

    " when this diff view is closed, wipe it out completely
    setlocal bufhidden=wipe

    let l:diff_buffer = bufnr('%')
    call add(l:before_git_diff, l:diff_buffer)

    " autocmd for when the buffer is closed
    augroup VCS
    exe printf('autocmd BufWipeout <buffer> call <SID>GitDiffRestore(%d, %d)', l:orig_window, l:orig_buffer)
    augroup end

    " try setting the buffer name
    try
      exe 'file ' . l:target . ':' . l:filename
    catch
    endtry

    " jump back to the other window
    wincmd p

    " set up an autocmd so that when the current buffer is wiped out, the diff
    " buffer is also wiped out
    " NOTE: this causes versions of vim up to and including 7.3 to crash, so we
    " are leaving it off for now
    if 0 && v:version >= 704
      augroup VCS
      exe printf('autocmd BufHidden <buffer> silent! bwipeout %d', l:diff_buffer)
      augroup end
    endif

  catch
    if l:split
      execute 'bwipeout ' . l:split
    endif

    " jump back to original window
    exe l:orig_window . "wincmd w"

    " restore options
    let [ &l:foldmethod, &l:foldcolumn, &l:wrap ] = b:before_git_diff
    unlet b:before_git_diff

    " show the error message
    redraw!
    echohl Error
    echo v:exception . ', thrown from ' . v:throwpoint
    echohl None
  endtry
endfunction




function! <SID>GitDiffRestore(orig_window, orig_buffer)
  let l:current_win = winnr()

  try
    " go through all windows for the original buffer, set the options back to
    " how they should have been
    for l:winnr in range(0, winnr('$'))
      exe l:winnr "wincmd w"
      if bufnr('%') == a:orig_buffer
        setlocal nodiff noscrollbind
        if exists('b:before_git_diff')
          let l:before_git_diff = b:before_git_diff
          unlet b:before_git_diff
        endif
        let [ &l:foldmethod, &l:foldcolumn, &l:wrap, l:_unused ] = l:before_git_diff
        normal! zv
      endif
    endfor
  finally
    exe l:current_win "wincmd w"
  endtry
endfunction



function! VCS#DetermineVCS()
  let l:path = expand("%:p:h")
  while strlen(l:path) > 1
    if isdirectory(l:path.'/.hg')
      return 'hg'
    endif
    if isdirectory(l:path.'/.git')
      return 'git'
    endif
    if isdirectory(l:path.'/.bzr')
      return 'bzr'
    endif
    if isdirectory(l:path.'/.svn')
      return 'svn'
    endif

    " remove another head component off the filename and try again
    let l:path = fnamemodify(l:path, ':h')
  endwhile
  return ''
endfunction


function! VCS#GitNavigateHistory(older)
  " what is the current file?
  if exists('b:VCS_git_file')
    let l:filename = b:VCS_git_file
  else
    if VCS#DetermineVCS() != 'git'
      " only works with GIT
      return
    endif
    let l:filename = expand('%')
  endif

  " get a list of revisions for this file
  let l:cmd = 'git log --format=%h '.shellescape(l:filename)
  let l:history = system(l:cmd)
  if v:shell_error != 0
    echohl Error
    echo 'Git log failed:'
    echo l:history
    echohl None
    return
  endif

  let l:hashes = split(l:history)

  " bail out if the file isn't tracked (no history)
  if ! len(l:hashes)
    echohl Error
    echo 'No commit history for '.l:filename
    echohl None
    return
  endif

  " what is the current hash?
  let l:current_hash = exists('b:VCS_git_hash') ? b:VCS_git_hash : ""
  let l:error = ""
  if strlen(l:current_hash)
    " try and find the current hash in the list of commits
    let l:idx = index(l:hashes, l:current_hash)

    " are we looking for an older one?
    if a:older
      let l:idx += 1
      if l:idx >= len(l:hashes)
        let l:error = 'No commits older than '.l:current_hash
      endif
    else
      " look for newer commit
      let l:idx -= 1
      if l:idx < 0
        let l:error = 'No commits newer than '.l:current_hash
      endif
    endif
  elseif a:older
    " not currently looking at a commit, so we just grab the latest one
    let l:idx = 0
  else
    let l:error = "Can't get newer commit hash without a specific commit hash"
  endif

  if strlen(l:error)
    echohl Error
    echo l:error
    echohl None
    return
  endif

  " what is the new hash to show?
  let l:new_hash = l:hashes[l:idx]

  " create a new window showing that revision
  call <SID>NewRevWindow(l:filename, l:new_hash, &l:filetype)
endfunction

function! <SID>NewRevWindow(path, rev, filetype)
  " what should the name of the buffer be?
  let l:bufname = a:rev.':'.a:path

  let l:bufnr = bufnr(l:bufname)

  " if the buffer already exists, just switch to it now
  if l:bufnr >= 0
    exe 'sbuffer' l:bufnr
    return
  endif

  " if the buffer doesn't exist, create it
  let l:bufnr = bufnr(l:bufname, 1)
  exe 'sbuffer' l:bufnr

  " set options in the new buffer
  setlocal buftype=nofile bufhidden=wipe

  " paste in the contents of the file as at that revision
  exe printf('read !git show %s:%s', a:rev, shellescape(a:path))

  " delete the empty blank line at the top of the file
  normal! ggdd

  " set variables so we remember what we're looking at
  let b:VCS_git_file = a:path
  let b:VCS_git_hash = a:rev

  " set filetype as per the original buffer
  let &l:filetype = a:filetype

  " set other options
  setlocal nomodified nomodifiable readonly
endfunction
