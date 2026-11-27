// Insert the policy at the start of the document head. HTML permits both the
// html and head start tags to be omitted. Keep the original doctype first.
const trivia = '(?:[\\t\\n\\f\\r \\uFEFF]|<!--[\\s\\S]*?-->)*';
const tagTail = '(?:[^>"\']|"[^"]*"|\'[^\']*\')*>';
const prologue = new RegExp('^' + trivia + '(?:<!doctype\\s+' + tagTail + trivia + ')?' +
  '(?:<html(?=[\\s>])' + tagTail + trivia + ')?(?:<head(?=[\\s>])' + tagTail + ')?', 'i');
const policy = '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; script-src \'unsafe-inline\'; style-src \'unsafe-inline\'; img-src data:; frame-src \'none\'; child-src \'none\'; connect-src \'none\'; form-action \'none\'; base-uri \'none\'">';

export function trustedHtml(html: string): string {
  const prefix = html.match(prologue);
  const offset = prefix ? prefix[0].length : 0;
  return html.slice(0, offset) + policy + html.slice(offset);
}
